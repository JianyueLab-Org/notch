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
        activeSession?.state == .waiting
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
        let sessionId = dict["session_id"] as? String ?? "default-\(agent)"
        let cwd = dict["cwd"] as? String ?? ""
        let title = dict["title"] as? String ?? ""
        let terminal = dict["terminal"] as? String ?? ""
        let pid = dict["pid"] as? Int

        let lowerState = rawState.lowercased()
        let resolvedState: AgentState
        if lowerState == "waiting" || event == "Notification" {
            resolvedState = .waiting
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

        // Priority for activeSession: if any session is waiting for action, highlight it!
        if let waiting = sessions.values.first(where: { $0.state == .waiting }) {
            activeSession = waiting
        } else if let working = sessions.values.first(where: { $0.state == .working }) {
            activeSession = working
        } else {
            activeSession = session
        }

        Log.lifecycle.notice("Agent event: \(agent) [\(sessionId)] -> \(resolvedState.rawValue) (event: \(event))")

        // Trigger notch prompt / alert when state requires attention or finishes
        if resolvedState == .waiting {
            // Needs user action (permission, question, interactive input)
            let alertTitle = title.isEmpty ? "Action Required" : title
            triggerAlert(
                AgentAlert(
                    sessionId: sessionId,
                    agent: agent,
                    state: .waiting,
                    title: alertTitle,
                    detail: "Approval or input requested",
                    terminal: terminal,
                    pid: pid,
                    timestamp: Date()
                ),
                autoDismissAfter: 6.0
            )
            NSSound.beep()
        } else if resolvedState == .completed && (previousState == .working || previousState == .waiting) {
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
        } else if resolvedState == .working && isShowingAlert && currentAlert?.state == .waiting && currentAlert?.sessionId == sessionId {
            // User provided input and this waiting agent resumed working; dismiss waiting alert
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

    private func pollAgentProcesses() {
        // Automatically check if known agent CLI tools are running
        let agentNames = ["claude", "agy", "opencode", "codex"]
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
                   !str.isEmpty, let pid = Int(str.components(separatedBy: .newlines).first ?? "") {
                    let agentKey = "process-\(name)-\(pid)"
                    if sessions[agentKey] == nil {
                        let capitalized = name == "agy" ? "Antigravity" : name.capitalized
                        let session = AgentSession(
                            id: agentKey,
                            agent: capitalized,
                            state: .working,
                            event: "AutoDetected",
                            title: "\(capitalized) Agent Process",
                            cwd: "",
                            terminal: "",
                            pid: pid,
                            lastUpdated: Date()
                        )
                        sessions[agentKey] = session
                        if activeSession == nil {
                            activeSession = session
                        }
                    }
                }
            } catch {
                // Ignore process check error
            }
        }
    }
}
