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

enum DarwinProcessHelper {

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
        do {
            try task.run()
            task.waitUntilExit()
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
        } catch {}

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

@MainActor
final class AgentHarnessController: ObservableObject {

    static let shared = AgentHarnessController()

    @Published var sessions: [String: AgentSession] = [:]
    @Published var activeSession: AgentSession?
    @Published var currentAlert: AgentAlert?
    @Published var isShowingAlert: Bool = false

    private let httpServer = AgentHTTPServer()
    private var dismissTimer: Timer?
    private var processPollTimer: Timer?

    var hasActiveAlert: Bool {
        isShowingAlert && currentAlert != nil
    }

    var isWorking: Bool {
        activeSession?.state == .working
    }

    var isWaiting: Bool {
        activeSession?.state.isWaiting == true
    }

    var isWaitingUser: Bool {
        activeSession?.state == .waitingUser
    }

    var isWaitingSubagent: Bool {
        activeSession?.state == .waitingSubagent
    }

    private init() {
        setupHTTPServer()
        startProcessPolling()
    }

    // MARK: - HTTP Ingestion

    private func setupHTTPServer() {
        httpServer.onDataReceived = { [weak self] data in
            Task { @MainActor in
                self?.handleIncomingData(data)
            }
        }
        httpServer.start(port: 7823)
    }

    func handleIncomingData(_ data: Data) {
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

    // MARK: - Alert HUD Presentation

    func triggerAlert(_ alert: AgentAlert, autoDismissAfter seconds: TimeInterval? = nil) {
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
        processPollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollAgentProcesses()
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

    private func pollAgentProcesses() {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-eo", "pid,ppid,%cpu,state,tty,comm,args"]
        let pipe = Pipe()
        ps.standardOutput = pipe

        do {
            try ps.run()
            ps.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return }
            processSnapshot(output: output)
        } catch {
            Log.lifecycle.error("Failed to run ps for agent detection: \(error.localizedDescription)")
        }
    }

    private func processSnapshot(output: String) {
        var rawEntries: [ProcessRawEntry] = []
        let lines = output.components(separatedBy: .newlines)

        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // Parse columns: pid ppid %cpu state tty comm args...
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

            guard let pid = Int(parts[0]),
                  let ppid = Int(parts[1]),
                  let cpu = Double(parts[2]) else { continue }

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

        // Match known AI agents
        var discoveredAgents: [(name: String, pid: Int, ppid: Int, cpu: Double, tty: String, args: String)] = []

        for entry in rawEntries {
            let lowerComm = entry.comm.lowercased()
            let lowerArgs = entry.args.lowercased()

            // Filter out system tools and self
            if lowerArgs.contains("grep") || lowerArgs.contains("notchnotch") {
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

            // 3. Codex CLI
            if lowerComm == "codex" || lowerArgs.contains("codex ") || lowerArgs.hasPrefix("codex") {
                discoveredAgents.append(("Codex", entry.pid, entry.ppid, entry.cpu, entry.tty, entry.args))
                continue
            }

            // 4. OpenCode CLI
            if lowerComm == "opencode" || lowerArgs.contains("opencode") || lowerArgs.contains("open-code") {
                discoveredAgents.append(("OpenCode", entry.pid, entry.ppid, entry.cpu, entry.tty, entry.args))
                continue
            }

            // 5. Aider CLI
            if lowerComm == "aider" || lowerArgs.contains("aider ") || lowerArgs.hasPrefix("aider") {
                discoveredAgents.append(("Aider", entry.pid, entry.ppid, entry.cpu, entry.tty, entry.args))
                continue
            }
        }

        var activeProcessKeys: Set<String> = []

        for agent in discoveredAgents {
            let key = "proc-\(agent.name.lowercased().replacingOccurrences(of: " ", with: "-"))-\(agent.pid)"
            activeProcessKeys.insert(key)

            // If an active HTTP hook session already covers this agent, skip creating a duplicate process session
            let hasFreshHttpHook = sessions.values.contains(where: {
                $0.source == .httpHook &&
                $0.agent.caseInsensitiveCompare(agent.name) == .orderedSame &&
                Date().timeIntervalSince($0.lastUpdated) < 180
            })
            if hasFreshHttpHook {
                continue
            }

            // Check if agent process has child processes actively working (e.g. running bash, git, tools)
            let activeChildren = rawEntries.filter { $0.ppid == agent.pid }
            let totalCpu = agent.cpu + activeChildren.reduce(0.0) { $0 + $1.cpu }
            let hasActiveTool = activeChildren.contains(where: { $0.cpu > 0.1 })

            let inferredState: AgentState
            if hasActiveTool || totalCpu > 1.5 {
                inferredState = .working
            } else {
                inferredState = .waitingUser
            }

            if var existing = sessions[key] {
                let previousState = existing.state
                existing.cpuPercent = totalCpu
                existing.lastUpdated = Date()

                if existing.state != inferredState {
                    existing.state = inferredState
                    Log.lifecycle.notice("Agent \(agent.name) state inferred: \(previousState.rawValue) -> \(inferredState.rawValue)")

                    // If transitioned from working to waitingUser, pop a notch alert
                    if previousState == .working && inferredState == .waitingUser {
                        triggerAlert(
                            AgentAlert(
                                sessionId: key,
                                agent: agent.name,
                                state: .waitingUser,
                                title: "\(agent.name) Needs Input",
                                detail: "Execution paused, awaiting user response",
                                terminal: existing.terminal,
                                pid: agent.pid,
                                timestamp: Date()
                            ),
                            autoDismissAfter: 7.0
                        )
                    }
                }
                sessions[key] = existing
            } else {
                // Discover CWD & Host GUI App
                let cwd = DarwinProcessHelper.getProcessCWD(pid: pid_t(agent.pid)) ?? ""
                let terminalName = DarwinProcessHelper.findGUIApp(for: pid_t(agent.pid))?.localizedName ?? ""

                let newSession = AgentSession(
                    id: key,
                    agent: agent.name,
                    state: inferredState,
                    event: "ProcessDetected",
                    title: "\(agent.name) Process",
                    cwd: cwd,
                    terminal: terminalName,
                    pid: agent.pid,
                    cpuPercent: totalCpu,
                    source: .processInspection,
                    lastUpdated: Date()
                )
                sessions[key] = newSession
                Log.lifecycle.notice("Discovered agent process: \(agent.name) [PID \(agent.pid)] in \(terminalName)")
            }
        }

        // Clean up terminated process sessions
        for (key, session) in sessions where key.hasPrefix("proc-") {
            if !activeProcessKeys.contains(key) {
                sessions.removeValue(forKey: key)
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
