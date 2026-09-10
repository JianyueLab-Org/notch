//
//  AgentHarnessController.swift
//  NotchNotch
//
//  Coordinates AI Agent harness detection, lifecycle events, state aggregation,
//  and presents notifications when action is required or a task finishes.
//

import AppKit
import Combine
import Foundation
import OSLog
import SwiftUI

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
            lastUpdated: Date()
        )

        let previousState = session.state
        session.state = resolvedState
        session.event = event
        if !title.isEmpty { session.title = title }
        if !cwd.isEmpty { session.cwd = cwd }
        if !terminal.isEmpty { session.terminal = terminal }
        if let pid { session.pid = pid }
        session.lastUpdated = Date()

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

        // 1. Try PID direct activation
        if let pid = session.pid, let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
            app.activate(options: [.activateIgnoringOtherApps])
            return
        }

        // 2. Try terminal name lookup
        if !session.terminal.isEmpty {
            let apps = NSWorkspace.shared.runningApplications
            if let termApp = apps.first(where: {
                $0.localizedName?.localizedCaseInsensitiveContains(session.terminal) == true ||
                $0.bundleIdentifier?.localizedCaseInsensitiveContains(session.terminal) == true
            }) {
                termApp.activate(options: [.activateIgnoringOtherApps])
                return
            }
        }

        // 3. Fallback: Check common terminal / IDE apps
        let candidates = ["ghostty", "iterm", "terminal", "warp", "cursor", "visual studio code"]
        let running = NSWorkspace.shared.runningApplications
        for c in candidates {
            if let app = running.first(where: { $0.localizedName?.localizedCaseInsensitiveContains(c) == true }) {
                app.activate(options: [.activateIgnoringOtherApps])
                return
            }
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
        // Automatically check if known agent CLI tools are running
        let agentNames = ["claude", "agy", "opencode", "codex"]
        var currentPids: [String: Int] = [:]

        for name in agentNames {
            let pgrep = Process()
            pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            pgrep.arguments = ["-x", name]
            let pipe = Pipe()
            pgrep.standardOutput = pipe
            do {
                try pgrep.run()
                pgrep.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !str.isEmpty {
                    for line in str.components(separatedBy: .newlines) {
                        if let pid = Int(line.trimmingCharacters(in: .whitespaces)) {
                            currentPids["process-\(name)-\(pid)"] = pid
                        }
                    }
                }
            } catch {
                // Ignore process check error
            }
        }

        // Clean up dead process sessions
        for (key, _) in sessions where key.hasPrefix("process-") {
            if currentPids[key] == nil {
                sessions.removeValue(forKey: key)
                if activeSession?.id == key {
                    activeSession = nil
                }
            }
        }

        // Register new process sessions
        for (key, pid) in currentPids {
            if sessions[key] == nil {
                let name = key.components(separatedBy: "-")[1]
                let capitalized = name == "agy" ? "Antigravity" : name.capitalized
                let session = AgentSession(
                    id: key,
                    agent: capitalized,
                    state: .working,
                    event: "AutoDetected",
                    title: "\(capitalized) Agent Process",
                    cwd: "",
                    terminal: "",
                    pid: pid,
                    lastUpdated: Date()
                )
                sessions[key] = session
            }
        }

        updateActiveSession()
    }
}
