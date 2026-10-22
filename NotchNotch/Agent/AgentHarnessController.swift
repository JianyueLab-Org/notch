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
                finished.wait()
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

    /// Fallback search among running GUI applications for common terminal or editor emulators.
    static func fallbackTerminalApp(hint: String = "") -> NSRunningApplication? {
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        if !hint.isEmpty {
            if let app = running.first(where: {
                $0.localizedName?.localizedCaseInsensitiveContains(hint) == true ||
                $0.bundleIdentifier?.localizedCaseInsensitiveContains(hint) == true
            }) {
                return app
            }
        }

        let candidates = ["ghostty", "zed", "iterm", "terminal", "warp", "cursor", "visual studio code"]
        for c in candidates {
            if let app = running.first(where: {
                $0.localizedName?.localizedCaseInsensitiveContains(c) == true ||
                $0.bundleIdentifier?.localizedCaseInsensitiveContains(c) == true
            }) {
                return app
            }
        }
        return nil
    }
}

// MARK: - Process Snapshot Parser

struct ProcessRawEntry {
    let pid: Int
    let ppid: Int
    let cpu: Double
    let state: String
    let tty: String
    let comm: String
    let args: String
}

struct DiscoveredAgentData: Sendable {
    let key: String
    let name: String
    let pid: Int
    let cwd: String
    let terminalName: String
    let totalCpu: Double
    let inferredState: AgentState
}

/// Skip the scanner's own grep and this app. A client whose arguments mention
/// the repo name is still an agent and must not be filtered out.
private nonisolated func isAgentScanNoise(comm: String, args: String) -> Bool {
    if comm == "grep" || comm == "rg" || comm.hasSuffix("/grep") || comm.hasSuffix("/rg") {
        return true
    }
    if args == "grep" || args == "rg" || args.hasPrefix("grep ") || args.hasPrefix("rg ") {
        return true
    }
    return comm.contains("notchnotch")
}

/// Grok and Codex are recognised from the executable name, not from a substring
/// of the whole command line. `ps comm` is truncated to 16 characters, so a
/// path like `~/.codex/.../bin/codex` shows up there as `/Users/jhl/.code`;
/// the full argv0 is the first token of `args`. Shell wrappers that only
/// mention the name inside a script (Grok's `__grok_*` shim) must not match.
private nonisolated func detectedExecutableAgent(comm: String, args: String) -> String? {
    let names = candidateExecutableNames(comm: comm, args: args)
    for name in names {
        switch name {
        case "grok":
            return "Grok"
        case "codex":
            // The managed app-server stays up with no tty and would pin the
            // island on REPLY. Match the argument, not the install path:
            // `~/.codex/.../app-server-daemon/bin/codex` is still the CLI.
            if commandArguments(args).contains("app-server") { return nil }
            return "Codex"
        default:
            break
        }
    }
    return nil
}

private nonisolated func candidateExecutableNames(comm: String, args: String) -> [String] {
    let tokens = args.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    var names: [String] = []
    if !comm.isEmpty { names.append(commandBasename(comm)) }
    if let first = tokens.first { names.append(commandBasename(first)) }

    let launchers: Set<String> = ["node", "nodejs", "python", "python3", "bun", "deno", "npx", "bunx", "pnpm", "yarn"]
    let launched = names.contains { launchers.contains($0) }
    if launched {
        for token in tokens.dropFirst() {
            if token.hasPrefix("-") { continue }
            names.append(commandBasename(token))
            break
        }
    }
    return names
}

/// Tokens after argv0. `ps` args begins with the executable, whose path may
/// contain `app-server` without the process being the managed server.
private nonisolated func commandArguments(_ args: String) -> [String] {
    args.split(whereSeparator: { $0.isWhitespace }).dropFirst().map { $0.lowercased() }
}

private nonisolated func commandBasename(_ token: String) -> String {
    let last = token.split(separator: "/").last.map(String.init) ?? token
    var name = last.lowercased()
    for suffix in [".js", ".mjs", ".cjs", ".exe"] where name.hasSuffix(suffix) {
        name.removeLast(suffix.count)
        break
    }
    return name
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
    private static let quietPollsBeforeWaiting = 3
    private static let httpIdleLimit: TimeInterval = 15 * 60
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

    private func setupHTTPServer() {
        httpServer.onDataReceived = { [weak self] data in
            Task { @MainActor in
                self?.handleIncomingData(data)
            }
        }
        httpServer.onListenerEvent = { [weak self] event in
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
        listenerStatus = .starting
        httpServer.start(port: 7823)
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
        let existingSessionId = sessions.keys.first(where: {
            sessions[$0]?.agent.caseInsensitiveCompare(agent) == .orderedSame
        })
        let sessionId = dict["session_id"] as? String ?? (existingSessionId ?? "default-\(agent)")
        let cwd = dict["cwd"] as? String ?? ""
        let title = dict["title"] as? String ?? ""
        let terminal = dict["terminal"] as? String ?? ""
        let pid = dict["pid"] as? Int

        let lowerState = rawState.lowercased()
        let lowerTitle = title.lowercased()
        let lowerEvent = event.lowercased()

        let resolvedState: AgentState
        if lowerState == "waitingsubagent" || lowerState == "waiting_subagent" || lowerState == "subagent" || lowerState == "subagents" || lowerState == "sub" {
            resolvedState = .waitingSubagent
        } else if lowerState == "waitinguser" || lowerState == "waiting_user" || lowerState == "reply" || lowerState == "waiting_reply" || lowerState == "action" {
            resolvedState = .waitingUser
        } else if lowerState == "waiting" || event == "Notification" {
            // Differentiate based on title or event details
            if lowerTitle.contains("subagent") || lowerTitle.contains("invoke_subagent") || lowerTitle.contains("task") || lowerEvent.contains("subagent") {
                resolvedState = .waitingSubagent
            } else {
                resolvedState = .waitingUser
            }
        } else if lowerState == "ended" || lowerState == "completed" || event == "Stop" || event == "SessionEnd" {
            resolvedState = .completed
        } else if lowerState == "working" || lowerState == "auto" || event == "PreToolUse" || event == "UserPromptSubmit" {
            // If PreToolUse is specifically launching a subagent or asking a question
            if lowerTitle.contains("invoke_subagent") || lowerTitle.contains("subagent") {
                resolvedState = .waitingSubagent
            } else if lowerTitle.contains("ask_question") || lowerTitle.contains("question") {
                resolvedState = .waitingUser
            } else {
                resolvedState = .working
            }
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

        let previousState = session.state
        session.state = resolvedState
        session.event = event
        session.source = .httpHook
        if !title.isEmpty { session.title = title }
        if !cwd.isEmpty { session.cwd = cwd }
        if !terminal.isEmpty { session.terminal = terminal }
        if let pid { session.pid = pid }
        session.lastUpdated = Date()

        if session.terminal.isEmpty, let pid = session.pid, let app = DarwinProcessHelper.findGUIApp(for: pid_t(pid)) {
            session.terminal = app.localizedName ?? ""
        }

        sessions[sessionId] = session
        updateActiveSession()

        Log.lifecycle.notice("Agent event: \(agent) [\(sessionId)] -> \(resolvedState.rawValue) (event: \(event))")

        // Trigger notch prompt / alert when state requires attention or finishes
        if resolvedState == .waitingUser {
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
        } else if resolvedState == .waitingSubagent {
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
        } else if resolvedState == .completed && (previousState == .working || previousState.isWaiting) {
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
            let dead = session.pid.map { !DarwinProcessHelper.isProcessAlive(pid_t($0)) } ?? false
            let idle = now.timeIntervalSince(session.lastUpdated)
            // A live process that is still waiting for the user stays on the island.
            // Sessions with no pid, and finished turns, do not.
            let expired = dead
                || (session.state == .completed && idle > Self.completedSessionLimit)
                || (session.pid == nil && idle > Self.httpIdleLimit)
            guard expired else { continue }
            sessions.removeValue(forKey: key)
            quietPollsBySession.removeValue(forKey: key)
            if activeSession?.id == key {
                activeSession = nil
            }
            if currentAlert?.sessionId == key {
                dismissAlert()
            }
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

        // 1. First attempt: climb kernel PPID tree to find hosting regular GUI app (Ghostty, Zed, Terminal, etc.)
        if let pid = session.pid {
            if let app = DarwinProcessHelper.findGUIApp(for: pid_t(pid)) {
                app.activate(options: [.activateIgnoringOtherApps])
                return
            }
        }

        // 2. Fallback: activate by terminal name hint or frontmost terminal application
        if let app = DarwinProcessHelper.fallbackTerminalApp(hint: session.terminal) {
            app.activate(options: [.activateIgnoringOtherApps])
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

    private func updateActiveSession() {
        if let waitingUser = sessions.values.first(where: { $0.state == .waitingUser }) {
            activeSession = waitingUser
        } else if let waitingSubagent = sessions.values.first(where: { $0.state == .waitingSubagent }) {
            activeSession = waitingSubagent
        } else if let working = sessions.values.first(where: { $0.state == .working }) {
            activeSession = working
        } else if let completed = sessions.values.first(where: { $0.state == .completed }) {
            activeSession = completed
        } else {
            activeSession = sessions.values.first
        }
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
            let (discovered, activeKeys) = parseProcessSnapshot(output: output)
            await applySnapshotResult(discovered: discovered, activeKeys: activeKeys)
        } catch {
            Log.lifecycle.error("Failed to run ps for agent detection: \(error.localizedDescription)")
        }
    }

    nonisolated private func parseProcessSnapshot(output: String) -> ([DiscoveredAgentData], Set<String>) {
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

        var discoveredAgents: [(name: String, pid: Int, ppid: Int, cpu: Double, tty: String, args: String)] = []

        for entry in rawEntries {
            let lowerComm = entry.comm.lowercased()
            let lowerArgs = entry.args.lowercased()

            if isAgentScanNoise(comm: lowerComm, args: lowerArgs) {
                continue
            }

            // Grok / Codex: executable basename only. See `detectedExecutableAgent`.
            if let name = detectedExecutableAgent(comm: lowerComm, args: lowerArgs) {
                discoveredAgents.append((name, entry.pid, entry.ppid, entry.cpu, entry.tty, entry.args))
                continue
            }

            // 1. Claude Code / Claude CLI
            if lowerComm.contains("claude") || lowerArgs.contains("claude") {
                if !lowerArgs.contains("--chrome-native-host") {
                    let name = (lowerArgs.contains("claude-agent-sdk") || lowerArgs.contains("claude-acp"))
                        ? "Claude (Zed ACP)"
                        : "Claude Code"
                    discoveredAgents.append((name, entry.pid, entry.ppid, entry.cpu, entry.tty, entry.args))
                    continue
                }
            }

            // 2. Antigravity CLI
            if lowerComm == "agy" || lowerArgs.contains("agy ") || lowerArgs.hasPrefix("agy") || lowerArgs.contains("/agy ") || lowerArgs.contains("antigravity") {
                discoveredAgents.append(("Antigravity", entry.pid, entry.ppid, entry.cpu, entry.tty, entry.args))
                continue
            }

            // 3. OpenCode CLI
            if lowerComm == "opencode" || lowerArgs.contains("opencode") || lowerArgs.contains("open-code") {
                discoveredAgents.append(("OpenCode", entry.pid, entry.ppid, entry.cpu, entry.tty, entry.args))
                continue
            }

            // 4. Aider CLI
            if lowerComm == "aider" || lowerArgs.contains("aider ") || lowerArgs.hasPrefix("aider") {
                discoveredAgents.append(("Aider", entry.pid, entry.ppid, entry.cpu, entry.tty, entry.args))
                continue
            }
        }

        var activeKeys: Set<String> = []
        var discoveredData: [DiscoveredAgentData] = []

        for agent in discoveredAgents {
            let key = "proc-\(agent.name.lowercased().replacingOccurrences(of: " ", with: "-"))-\(agent.pid)"
            activeKeys.insert(key)

            let activeChildren = rawEntries.filter { $0.ppid == agent.pid }
            let totalCpu = agent.cpu + activeChildren.reduce(0.0) { $0 + $1.cpu }
            let hasActiveTool = activeChildren.contains(where: { $0.cpu > 0.1 })

            let inferredState: AgentState
            if hasActiveTool || totalCpu > 1.5 {
                inferredState = .working
            } else {
                inferredState = .waitingUser
            }

            let cwd = DarwinProcessHelper.getProcessCWD(pid: pid_t(agent.pid)) ?? ""
            let terminalName = DarwinProcessHelper.findGUIApp(for: pid_t(agent.pid))?.localizedName ?? ""

            discoveredData.append(DiscoveredAgentData(
                key: key,
                name: agent.name,
                pid: agent.pid,
                cwd: cwd,
                terminalName: terminalName,
                totalCpu: totalCpu,
                inferredState: inferredState
            ))
        }

        return (discoveredData, activeKeys)
    }

    private func applySnapshotResult(discovered: [DiscoveredAgentData], activeKeys: Set<String>) {
        guard isMonitoringEnabled && isProcessScanningEnabled else { return }
        for item in discovered {
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
