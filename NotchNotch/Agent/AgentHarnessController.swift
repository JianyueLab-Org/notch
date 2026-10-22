//
//  AgentHarnessController.swift
//  NotchNotch
//
//  Coordinates AI Agent harness detection, lifecycle events, state aggregation,
//  and presents notifications when action is required or a task finishes.
//

import AppKit
import Combine
import Darwin.libproc
import Foundation
import OSLog
import SwiftUI

// MARK: - Darwin Process & Window Focusing Helpers

nonisolated enum DarwinProcessHelper {

    /// Retrieves current working directory (CWD) of any process directly via kernel proc_pidinfo.
    static func getProcessCWD(pid: pid_t) -> String? {
        var vpi = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let ret = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vpi, size)
        guard ret > 0 else { return nil }
        return withUnsafePointer(to: &vpi.pvi_cdir.vip_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { cStr in
                let path = String(cString: cStr).trimmingCharacters(in: .whitespacesAndNewlines)
                return path.isEmpty ? nil : path
            }
        }
    }

    /// Gets parent PID and command name of any process via proc_bsdinfo.
    static func getParentPID(of pid: pid_t) -> (ppid: pid_t, comm: String)? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let ret = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard ret > 0 else { return nil }
        let comm = withUnsafePointer(to: &info.pbi_comm) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 16) { cStr in
                String(cString: cStr)
            }
        }
        return (pid_t(info.pbi_ppid), comm)
    }

    /// Recursively climbs up the PPID hierarchy to discover the hosting GUI application
    /// (e.g. Ghostty, Zed, Terminal, iTerm2, VS Code, Cursor, Warp).
    static func findGUIApp(for pid: pid_t) -> NSRunningApplication? {
        var cur = pid
        var hitTmux = false
        var visited = Set<pid_t>()

        for _ in 0..<12 {
            if visited.contains(cur) || cur <= 1 { break }
            visited.insert(cur)

            if let app = NSRunningApplication(processIdentifier: cur), app.activationPolicy == .regular {
                return app
            }

            guard let parent = getParentPID(of: cur) else { break }
            if parent.comm.contains("tmux") {
                hitTmux = true
            }
            cur = parent.ppid
        }

        if hitTmux {
            if let tmuxApp = resolveTmuxClientGUIApp(for: pid) {
                return tmuxApp
            }
        }

        return nil
    }

    /// If agent is running inside a tmux session, finds the tmux client terminal's GUI application.
    static func resolveTmuxClientGUIApp(for agentPid: pid_t) -> NSRunningApplication? {
        let tmuxPaths = ["/opt/homebrew/bin/tmux", "/run/current-system/sw/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        guard let tmuxPath = tmuxPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: tmuxPath)
        task.arguments = ["list-clients", "-F", "#{client_pid}"]
        let pipe = Pipe()
        task.standardOutput = pipe
        let finished = DispatchGroup()
        finished.enter()
        task.terminationHandler = { _ in finished.leave() }
        do {
            try task.run()
            // A stuck tmux server would otherwise block whoever asked to focus the session.
            if finished.wait(timeout: .now() + 2) == .timedOut {
                task.terminate()
                // SIGTERM can be ignored too; never wait on it unbounded.
                _ = finished.wait(timeout: .now() + 0.5)
                return nil
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let str = String(data: data, encoding: .utf8) {
                for line in str.components(separatedBy: .newlines) {
                    if let clientPid = Int(line.trimmingCharacters(in: .whitespaces)), clientPid > 1 {
                        if let app = findGUIAppDirect(for: pid_t(clientPid)) {
                            return app
                        }
                    }
                }
            }
        } catch {
            finished.leave()
        }

        return nil
    }

    private static func findGUIAppDirect(for pid: pid_t) -> NSRunningApplication? {
        var cur = pid
        var visited = Set<pid_t>()
        for _ in 0..<10 {
            if visited.contains(cur) || cur <= 1 { break }
            visited.insert(cur)
            if let app = NSRunningApplication(processIdentifier: cur), app.activationPolicy == .regular {
                return app
            }
            guard let parent = getParentPID(of: cur) else { break }
            cur = parent.ppid
        }
        return nil
    }

    /// `kill(pid, 0)` probes liveness. `EPERM` still means the process exists.
    static func isProcessAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Terminals and editors the fallback may activate, in preference order.
    /// `terminal` arrives in an unauthenticated HTTP body, so it only picks from
    /// this list, by exact bundle id or name, and never names an arbitrary app.
    private static let knownTerminals: [(bundleID: String, names: [String])] = [
        ("com.mitchellh.ghostty", ["ghostty"]),
        ("dev.zed.Zed", ["zed"]),
        ("com.googlecode.iterm2", ["iterm2", "iterm"]),
        ("com.apple.Terminal", ["terminal"]),
        ("dev.warp.Warp-Stable", ["warp"]),
        ("com.todesktop.230313mzl4w4u92", ["cursor"]),
        ("com.microsoft.VSCode", ["visual studio code", "code", "vscode"]),
        ("net.kovidgoyal.kitty", ["kitty"]),
        ("org.alacritty", ["alacritty"]),
        ("com.github.wez.wezterm", ["wezterm"]),
    ]

    /// Fallback search among running GUI applications for common terminal or editor emulators.
    static func fallbackTerminalApp(hint: String = "") -> NSRunningApplication? {
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        func runningApp(_ bundleID: String) -> NSRunningApplication? {
            running.first { $0.bundleIdentifier?.caseInsensitiveCompare(bundleID) == .orderedSame }
        }

        let wanted = hint.trimmingCharacters(in: .whitespaces).lowercased()
        if !wanted.isEmpty,
           let entry = knownTerminals.first(where: { $0.bundleID.lowercased() == wanted || $0.names.contains(wanted) }),
           let app = runningApp(entry.bundleID) {
            return app
        }

        for entry in knownTerminals {
            if let app = runningApp(entry.bundleID) {
                return app
            }
        }
        return nil
    }
}

// MARK: - Process Snapshot Parser

struct DiscoveredAgentData: Sendable {
    let key: String
    let name: String
    let pid: Int
    let cwd: String
    let terminalName: String
    let totalCpu: Double
    let inferredState: AgentState
}

enum AgentListenerStatus: Equatable {
    case stopped
    case starting
    case ready
    case failed
}

@MainActor
final class AgentHarnessController: ObservableObject {

    static let shared = AgentHarnessController()
    static let monitoringEnabledKey = "co.jianyuelab.NotchNotch.agentMonitoringEnabled"
    static let processScanningEnabledKey = "co.jianyuelab.NotchNotch.agentProcessScanningEnabled"

    @Published var isMonitoringEnabled: Bool = true
    @Published var isProcessScanningEnabled: Bool = true
    @Published var sessions: [String: AgentSession] = [:]
    @Published var activeSession: AgentSession?
    @Published var currentAlert: AgentAlert?
    @Published var isShowingAlert: Bool = false
    @Published private(set) var listenerStatus: AgentListenerStatus = .stopped

    private let httpServer = AgentHTTPServer()
    private var dismissTimer: Timer?
    private var processPollTimer: Timer?
    private var sessionPruneTimer: Timer?
    private var isScanning: Bool = false
    /// Consecutive low-CPU samples per scanned session. One quiet poll is not "needs input".
    private var quietPollsBySession: [String: Int] = [:]
    /// Hook session id -> pid whose terminal lookup has started. One lookup per pair.
    private var terminalLookups: [String: Int] = [:]
    /// cwd and hosting terminal per scanned session. Resolving the terminal can
    /// shell out to tmux, so it happens once per process, not on every poll.
    private var processDetailsCache: [String: (cwd: String, terminal: String)] = [:]
    private static let quietPollsBeforeWaiting = 3
    private static let completedSessionLimit: TimeInterval = 90

    var hasActiveAlert: Bool {
        isMonitoringEnabled && isShowingAlert && currentAlert != nil
    }

    var isWorking: Bool {
        isMonitoringEnabled && activeSession?.state == .working
    }

    var isWaiting: Bool {
        isMonitoringEnabled && activeSession?.state.isWaiting == true
    }

    var isWaitingUser: Bool {
        isMonitoringEnabled && activeSession?.state == .waitingUser
    }

    var isWaitingSubagent: Bool {
        isMonitoringEnabled && activeSession?.state == .waitingSubagent
    }

    private init() {
        if UserDefaults.standard.object(forKey: Self.monitoringEnabledKey) != nil {
            self.isMonitoringEnabled = UserDefaults.standard.bool(forKey: Self.monitoringEnabledKey)
        } else {
            self.isMonitoringEnabled = true
        }

        if UserDefaults.standard.object(forKey: Self.processScanningEnabledKey) != nil {
            self.isProcessScanningEnabled = UserDefaults.standard.bool(forKey: Self.processScanningEnabledKey)
        } else {
            self.isProcessScanningEnabled = true
        }

        if isMonitoringEnabled {
            setupHTTPServer()
            if isProcessScanningEnabled {
                startProcessPolling()
            }
        }
    }

    // MARK: - HTTP Ingestion

    /// Safe to call while already running: a bound listener keeps `.ready`, and
    /// the server re-reports it instead of leaving the status on "starting".
    private func setupHTTPServer() {
        if listenerStatus != .ready {
            listenerStatus = .starting
        }
        httpServer.start(
            port: 7823,
            onData: { [weak self] data in
                Task { @MainActor in
                    self?.handleIncomingData(data)
                }
            },
            onEvent: { [weak self] event in
                Task { @MainActor in
                    guard let self, self.isMonitoringEnabled else { return }
                    switch event {
                    case .ready:
                        self.listenerStatus = .ready
                    case .failed:
                        self.listenerStatus = .failed
                    }
                }
            }
        )
        startSessionPruneTimer()
    }

    func handleIncomingData(_ data: Data) {
        guard isMonitoringEnabled else { return }
        guard let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return
        }
        handleIncomingEvent(dict)
    }

    func handleIncomingEvent(_ dict: [String: Any]) {
        let rawState = dict["state"] as? String ?? "Working"
        let agent = dict["agent"] as? String ?? "Agent"
        let event = dict["event"] as? String ?? ""
        let sessionId: String
        if let provided = dict["session_id"] as? String, !provided.isEmpty {
            // `proc-` keys belong to the process scanner, which deletes them when the process goes.
            sessionId = provided.hasPrefix("proc-") ? "hook-\(provided)" : provided
        } else {
            // No id: continue this agent's most recently updated hook session.
            // Dictionary order is arbitrary, and a scanned session is not ours to take over.
            sessionId = sessions.values
                .filter { !$0.id.hasPrefix("proc-") && $0.agent.caseInsensitiveCompare(agent) == .orderedSame }
                .max(by: { $0.lastUpdated < $1.lastUpdated })?
                .id ?? "default-\(agent)"
        }
        let cwd = dict["cwd"] as? String ?? ""
        let title = dict["title"] as? String ?? ""
        let terminal = dict["terminal"] as? String ?? ""
        let pid = Self.validatedPID(dict["pid"])

        let lowerState = rawState.lowercased()
        let lowerEvent = event.lowercased()

        let resolvedState: AgentState
        if lowerState == "waitingsubagent" || lowerState == "waiting_subagent" || lowerState == "subagent" || lowerState == "subagents" || lowerState == "sub" {
            resolvedState = .waitingSubagent
        } else if lowerState == "waitinguser" || lowerState == "waiting_user" || lowerState == "reply" || lowerState == "waiting_reply" || lowerState == "action" {
            resolvedState = .waitingUser
        } else if lowerState == "waiting" || event == "Notification" {
            // `title` is free text for display; only `state` and `event` decide state.
            resolvedState = lowerEvent.contains("subagent") ? .waitingSubagent : .waitingUser
        } else if lowerState == "ended" || lowerState == "completed" || event == "Stop" || event == "SessionEnd" {
            resolvedState = .completed
        } else if lowerState == "working" || lowerState == "auto" || event == "PreToolUse" || event == "UserPromptSubmit" {
            resolvedState = .working
        } else {
            resolvedState = .idle
        }

        var session = sessions[sessionId] ?? AgentSession(
            id: sessionId,
            agent: agent,
            state: resolvedState,
            event: event,
            title: title,
            cwd: cwd,
            terminal: terminal,
            pid: pid,
            cpuPercent: nil,
            source: .httpHook,
            lastUpdated: Date()
        )

        // nil for a new session: its first waiting event is a transition too.
        let previousState: AgentState? = sessions[sessionId]?.state
        session.state = resolvedState
        session.event = event
        session.source = .httpHook
        if !title.isEmpty { session.title = title }
        if !cwd.isEmpty { session.cwd = cwd }
        if !terminal.isEmpty { session.terminal = terminal }
        if let pid { session.pid = pid }
        session.lastUpdated = Date()

        sessions[sessionId] = session
        if session.terminal.isEmpty, let pid = session.pid, terminalLookups[sessionId] != pid {
            terminalLookups[sessionId] = pid
            resolveTerminal(sessionId: sessionId, pid: pid)
        }
        evictExcessHookSessions(keeping: sessionId)
        updateActiveSession()

        Log.lifecycle.notice("Agent event: \(agent) [\(sessionId)] -> \(resolvedState.rawValue) (event: \(event))")

        // Alert on a transition only. A hook that repeats the same state must not re-beep.
        if resolvedState == .waitingUser && previousState != .waitingUser {
            // Needs user reply (permission, question, interactive input)
            let alertTitle = title.isEmpty ? "Reply Needed" : title
            triggerAlert(
                AgentAlert(
                    sessionId: sessionId,
                    agent: agent,
                    state: .waitingUser,
                    title: alertTitle,
                    detail: "Input or approval required",
                    terminal: terminal,
                    pid: pid,
                    timestamp: Date()
                ),
                autoDismissAfter: 7.0
            )
            NSSound.beep()
        } else if resolvedState == .waitingSubagent && previousState != .waitingSubagent {
            // Subagent execution in background - subtle alert without audio beep
            let alertTitle = title.isEmpty ? "Subagent Active" : title
            triggerAlert(
                AgentAlert(
                    sessionId: sessionId,
                    agent: agent,
                    state: .waitingSubagent,
                    title: alertTitle,
                    detail: "Delegated subagent running",
                    terminal: terminal,
                    pid: pid,
                    timestamp: Date()
                ),
                autoDismissAfter: 3.5
            )
        } else if resolvedState == .completed && (previousState == .working || previousState?.isWaiting == true) {
            // Turn completed
            let alertTitle = title.isEmpty ? "Task Completed" : title
            triggerAlert(
                AgentAlert(
                    sessionId: sessionId,
                    agent: agent,
                    state: .completed,
                    title: alertTitle,
                    detail: "Finished execution successfully",
                    terminal: terminal,
                    pid: pid,
                    timestamp: Date()
                ),
                autoDismissAfter: 3.5
            )
        } else if resolvedState == .working && isShowingAlert && currentAlert?.state.isWaiting == true && currentAlert?.sessionId == sessionId {
            // User provided input or subagent finished and agent resumed working; dismiss alert
            dismissAlert()
        }
    }

    /// `pid_t` is 32-bit, so an out-of-range JSON number must be rejected, not
    /// trapped on. 0 and 1 are the kernel and launchd, never an agent.
    private static func validatedPID(_ value: Any?) -> Int? {
        guard let raw = value as? Int, let pid = Int32(exactly: raw), pid > 1 else { return nil }
        return Int(pid)
    }

    /// Climbing the process tree can shell out to tmux and wait on it, so it
    /// runs off the main actor.
    private func resolveTerminal(sessionId: String, pid: Int) {
        guard let pid32 = pid_t(exactly: pid) else { return }
        Task.detached(priority: .utility) { [weak self] in
            guard let name = DarwinProcessHelper.findGUIApp(for: pid32)?.localizedName, !name.isEmpty else { return }
            await self?.applyResolvedTerminal(name, sessionId: sessionId, pid: pid)
        }
    }

    private func applyResolvedTerminal(_ name: String, sessionId: String, pid: Int) {
        guard var session = sessions[sessionId], session.pid == pid, session.terminal.isEmpty else { return }
        session.terminal = name
        sessions[sessionId] = session
        updateActiveSession()
    }

    /// Any local process can mint session ids, so hook sessions are capped.
    private func evictExcessHookSessions(keeping keep: String) {
        let hookSessions = sessions.values.filter { $0.source == .httpHook && $0.id != keep }
        let excess = hookSessions.count + 1 - NotchConfiguration.agentMaxHookSessions
        guard excess > 0 else { return }
        for session in hookSessions.sorted(by: { $0.lastUpdated < $1.lastUpdated }).prefix(excess) {
            removeSession(session.id)
        }
    }

    private func removeSession(_ key: String) {
        sessions.removeValue(forKey: key)
        quietPollsBySession.removeValue(forKey: key)
        terminalLookups.removeValue(forKey: key)
        processDetailsCache.removeValue(forKey: key)
        if activeSession?.id == key {
            activeSession = nil
        }
        if currentAlert?.sessionId == key {
            dismissAlert()
        }
    }

    // MARK: - Lifecycle & Monitoring Controls

    func setMonitoringEnabled(_ enabled: Bool) {
        isMonitoringEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.monitoringEnabledKey)

        if enabled {
            setupHTTPServer()
            if isProcessScanningEnabled {
                startProcessPolling()
            }
        } else {
            stopAll()
        }
    }

    func setProcessScanningEnabled(_ enabled: Bool) {
        isProcessScanningEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.processScanningEnabledKey)

        if isMonitoringEnabled && enabled {
            startProcessPolling()
        } else {
            stopProcessPolling()
        }
    }

    private func stopAll() {
        stopProcessPolling()
        sessionPruneTimer?.invalidate()
        sessionPruneTimer = nil
        httpServer.stop()
        listenerStatus = .stopped
        dismissAlert()
        sessions.removeAll()
        quietPollsBySession.removeAll()
        terminalLookups.removeAll()
        processDetailsCache.removeAll()
        activeSession = nil
    }

    private func startSessionPruneTimer() {
        sessionPruneTimer?.invalidate()
        sessionPruneTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pruneStaleSessions()
            }
        }
    }

    /// HTTP sessions have no process-snapshot exit. A dead pid, a finished turn,
    /// or a hook that never writes again must not pin the island on REPLY.
    private func pruneStaleSessions() {
        let now = Date()
        var removed = false
        for (key, session) in sessions where session.source == .httpHook {
            let dead = session.pid
                .flatMap { pid_t(exactly: $0) }
                .map { !DarwinProcessHelper.isProcessAlive($0) } ?? false
            let idle = now.timeIntervalSince(session.lastUpdated)
            // A live pid is not enough: an interrupted agent sends no Stop and would
            // stay BUSY or REPLY forever. Once dropped, process scanning infers it.
            let expired = dead
                || (session.state == .completed && idle > Self.completedSessionLimit)
                || idle > NotchConfiguration.agentHookInactivityTimeout
            guard expired else { continue }
            removeSession(key)
            removed = true
        }
        if removed {
            updateActiveSession()
        }
    }

    private func stopProcessPolling() {
        processPollTimer?.invalidate()
        processPollTimer = nil
        isScanning = false
        for key in sessions.keys where key.hasPrefix("proc-") {
            sessions.removeValue(forKey: key)
        }
        updateActiveSession()
    }

    // MARK: - Alert HUD Presentation

    func triggerAlert(_ alert: AgentAlert, autoDismissAfter seconds: TimeInterval? = nil) {
        guard isMonitoringEnabled else { return }
        currentAlert = alert
        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
            isShowingAlert = true
        }

        dismissTimer?.invalidate()
        if let seconds {
            dismissTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.dismissAlert()
                }
            }
        }
    }

    func dismissAlert() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        withAnimation(.spring(response: 0.25, dampingFraction: 0.88)) {
            isShowingAlert = false
        }
    }

    // MARK: - Focus Agent Window

    func focusActiveAgent() {
        guard let session = activeSession else { return }
        focusSession(session)
    }

    func focusSession(_ session: AgentSession) {
        dismissAlert()

        let pid = session.pid.flatMap { pid_t(exactly: $0) }
        let hint = session.terminal
        // The tree climb can wait on tmux, so it runs off the main actor.
        Task.detached(priority: .userInitiated) {
            // 1. First attempt: climb kernel PPID tree to find hosting regular GUI app (Ghostty, Zed, Terminal, etc.)
            let hostPid = pid.flatMap { DarwinProcessHelper.findGUIApp(for: $0)?.processIdentifier }
            await MainActor.run {
                if let hostPid, let app = NSRunningApplication(processIdentifier: hostPid) {
                    app.activate(options: [.activateIgnoringOtherApps])
                    return
                }
                // 2. Fallback: activate by terminal name hint or the first running known terminal
                DarwinProcessHelper.fallbackTerminalApp(hint: hint)?.activate(options: [.activateIgnoringOtherApps])
            }
        }
    }

    // MARK: - Process Auto-Detection

    private func startProcessPolling() {
        guard isMonitoringEnabled && isProcessScanningEnabled else { return }
        processPollTimer?.invalidate()
        processPollTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isMonitoringEnabled, self.isProcessScanningEnabled, !self.isScanning else { return }
                self.isScanning = true
                Task.detached(priority: .utility) { [weak self] in
                    defer {
                        Task { @MainActor [weak self] in
                            self?.isScanning = false
                        }
                    }
                    await self?.pollAgentProcessesBackground()
                }
            }
        }
    }

    /// Highest-priority state wins; within a state, the most recently updated
    /// session. Dictionary order is arbitrary and would make the pick flicker.
    private func updateActiveSession() {
        let byRecency = sessions.values.sorted {
            $0.lastUpdated != $1.lastUpdated ? $0.lastUpdated > $1.lastUpdated : $0.id < $1.id
        }
        for state in [AgentState.waitingUser, .waitingSubagent, .working, .completed] {
            if let match = byRecency.first(where: { $0.state == state }) {
                activeSession = match
                return
            }
        }
        activeSession = byRecency.first
    }

    private func processDetailsSnapshot() -> [String: (cwd: String, terminal: String)] {
        processDetailsCache
    }

    nonisolated private func pollAgentProcessesBackground() async {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-eo", "pid,ppid,%cpu,state,tty,comm,args"]
        // `%cpu` follows LC_NUMERIC. `Double` only accepts a dot, so a comma locale drops every row.
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        environment["LANG"] = "C"
        environment["LC_NUMERIC"] = "C"
        ps.environment = environment
        let pipe = Pipe()
        ps.standardOutput = pipe

        do {
            try ps.run()
            // CRITICAL: Read pipe data BEFORE waitUntilExit to prevent 64KB pipe buffer deadlock!
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            ps.waitUntilExit()
            guard let output = String(data: data, encoding: .utf8) else { return }
            let cachedDetails = await processDetailsSnapshot()
            let (discovered, activeKeys) = parseProcessSnapshot(output: output, cachedDetails: cachedDetails)
            await applySnapshotResult(discovered: discovered, activeKeys: activeKeys)
        } catch {
            Log.lifecycle.error("Failed to run ps for agent detection: \(error.localizedDescription)")
        }
    }

    nonisolated private func parseProcessSnapshot(
        output: String,
        cachedDetails: [String: (cwd: String, terminal: String)]
    ) -> ([DiscoveredAgentData], Set<String>) {
        var rawEntries: [ProcessRawEntry] = []
        let lines = output.components(separatedBy: .newlines)

        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            var parts: [String] = []
            var currentToken = ""
            var charIndex = trimmed.startIndex

            while charIndex < trimmed.endIndex && parts.count < 6 {
                let char = trimmed[charIndex]
                if char.isWhitespace {
                    if !currentToken.isEmpty {
                        parts.append(currentToken)
                        currentToken = ""
                    }
                } else {
                    currentToken.append(char)
                }
                charIndex = trimmed.index(after: charIndex)
            }

            guard parts.count >= 6 else { continue }
            let args = String(trimmed[charIndex...]).trimmingCharacters(in: .whitespaces)

            let cpuText = parts[2].replacingOccurrences(of: ",", with: ".")
            guard let pid = Int(parts[0]),
                  let ppid = Int(parts[1]),
                  let cpu = Double(cpuText) else { continue }

            rawEntries.append(ProcessRawEntry(
                pid: pid,
                ppid: ppid,
                cpu: cpu,
                state: parts[3],
                tty: parts[4],
                comm: parts[5],
                args: args.isEmpty ? parts[5] : args
            ))
        }

        var activeKeys: Set<String> = []
        var discoveredData: [DiscoveredAgentData] = []

        // Matching rules and de-duplication live in `AgentProcessMatcher`.
        for agent in AgentProcessMatcher.discover(rawEntries) {
            let key = "proc-\(agent.name.lowercased().replacingOccurrences(of: " ", with: "-"))-\(agent.pid)"
            activeKeys.insert(key)

            let usage = AgentProcessMatcher.cpuUsage(of: agent, in: rawEntries)
            let inferredState: AgentState = (usage.hasActiveTool || usage.total > 1.5) ? .working : .waitingUser

            let details: (cwd: String, terminal: String)
            if let cached = cachedDetails[key] {
                details = cached
            } else if let pid = pid_t(exactly: agent.pid) {
                details = (
                    DarwinProcessHelper.getProcessCWD(pid: pid) ?? "",
                    DarwinProcessHelper.findGUIApp(for: pid)?.localizedName ?? ""
                )
            } else {
                details = ("", "")
            }

            discoveredData.append(DiscoveredAgentData(
                key: key,
                name: agent.name,
                pid: agent.pid,
                cwd: details.cwd,
                terminalName: details.terminal,
                totalCpu: usage.total,
                inferredState: inferredState
            ))
        }

        return (discoveredData, activeKeys)
    }

    private func applySnapshotResult(discovered: [DiscoveredAgentData], activeKeys: Set<String>) {
        guard isMonitoringEnabled && isProcessScanningEnabled else { return }
        for item in discovered {
            processDetailsCache[item.key] = (item.cwd, item.terminalName)
            let hasFreshHttpHook = sessions.values.contains(where: {
                $0.source == .httpHook &&
                $0.agent.caseInsensitiveCompare(item.name) == .orderedSame &&
                Date().timeIntervalSince($0.lastUpdated) < 180
            })
            if hasFreshHttpHook {
                continue
            }

            if var existing = sessions[item.key] {
                let previousState = existing.state
                existing.cpuPercent = item.totalCpu
                existing.lastUpdated = Date()

                var inferred = item.inferredState
                if previousState == .working && inferred == .waitingUser {
                    let samples = (quietPollsBySession[item.key] ?? 0) + 1
                    quietPollsBySession[item.key] = samples
                    if samples < Self.quietPollsBeforeWaiting {
                        inferred = .working
                    }
                } else if inferred == .working {
                    quietPollsBySession[item.key] = 0
                }

                if existing.state != inferred {
                    existing.state = inferred
                    Log.lifecycle.notice("Agent \(item.name) state inferred: \(previousState.rawValue) -> \(inferred.rawValue)")

                    if previousState == .working && inferred == .waitingUser {
                        quietPollsBySession[item.key] = 0
                        triggerAlert(
                            AgentAlert(
                                sessionId: item.key,
                                agent: item.name,
                                state: .waitingUser,
                                title: "\(item.name) Needs Input",
                                detail: "Execution paused, awaiting user response",
                                terminal: existing.terminal,
                                pid: item.pid,
                                timestamp: Date()
                            ),
                            autoDismissAfter: 7.0
                        )
                    }
                }
                if inferred == .working && previousState.isWaiting && isShowingAlert && currentAlert?.sessionId == item.key {
                    dismissAlert()
                }
                sessions[item.key] = existing
            } else {
                let newSession = AgentSession(
                    id: item.key,
                    agent: item.name,
                    state: item.inferredState,
                    event: "ProcessDetected",
                    title: "\(item.name) Process",
                    cwd: item.cwd,
                    terminal: item.terminalName,
                    pid: item.pid,
                    cpuPercent: item.totalCpu,
                    source: .processInspection,
                    lastUpdated: Date()
                )
                sessions[item.key] = newSession
                Log.lifecycle.notice("Discovered agent process: \(item.name) [PID \(item.pid)] in \(item.terminalName)")
            }
        }

        for key in processDetailsCache.keys where !activeKeys.contains(key) {
            processDetailsCache.removeValue(forKey: key)
        }

        for (key, session) in sessions where key.hasPrefix("proc-") {
            if !activeKeys.contains(key) {
                sessions.removeValue(forKey: key)
                quietPollsBySession.removeValue(forKey: key)
                if activeSession?.id == key {
                    activeSession = nil
                }
                if session.state == .working || session.state == .waitingUser {
                    triggerAlert(
                        AgentAlert(
                            sessionId: key,
                            agent: session.agent,
                            state: .completed,
                            title: "\(session.agent) Finished",
                            detail: "Process exited",
                            terminal: session.terminal,
                            pid: session.pid,
                            timestamp: Date()
                        ),
                        autoDismissAfter: 3.5
                    )
                }
            }
        }

        updateActiveSession()
    }
}
