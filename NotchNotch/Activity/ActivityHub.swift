//
//  ActivityHub.swift
//  NotchNotch
//
//  Every session any plugin reports, the one the island follows, and the
//  alert banner. Knows nothing about particular agents: a session is a key,
//  a state, a label, a title and maybe a pid.
//

import AppKit
import Combine
import OSLog
import SwiftUI

struct ActivityAlert: Equatable, Sendable {
    let id = UUID()
    let sessionKey: String
    let label: String
    let state: ActivityState
    /// Conversation title; empty when the plugin reported none.
    let title: String
    let pid: Int?
    let timestamp: Date
}

@MainActor
final class ActivityHub: ObservableObject {

    static let shared = ActivityHub()

    @Published private(set) var sessions: [String: ActivitySession] = [:]
    @Published private(set) var activeSession: ActivitySession?
    @Published private(set) var currentAlert: ActivityAlert?
    @Published private(set) var isShowingAlert = false

    private var dismissTimer: Timer?
    private var pruneTimer: Timer?
    private static let completedSessionLimit: TimeInterval = 90

    var isWorking: Bool { activeSession?.state == .working }
    var isWaitingUser: Bool { activeSession?.state == .waitingUser }
    var isWaitingSubagent: Bool { activeSession?.state == .waitingSubagent }

    private init() {
        // Also re-evaluates pid dedup, whose hold expires with time, not with a message.
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.prune() }
        }
    }

    // MARK: - Ingestion

    func apply(_ message: PluginMessage, pluginID: String, source: ActivitySource) {
        switch message {
        case .sessionUpdate(let update):
            apply(update, pluginID: pluginID, source: source)
        case .sessionEnd(let sessionID, let alert):
            end(ActivityRules.key(pluginID: pluginID, sessionID: sessionID), alert: alert)
        }
    }

    private func apply(_ update: SessionUpdate, pluginID: String, source: ActivitySource) {
        let sessionID = update.id.isEmpty ? continuedSessionID(label: update.label, pluginID: pluginID) : update.id
        let key = ActivityRules.key(pluginID: pluginID, sessionID: sessionID)
        let previous = sessions[key]

        var session = previous ?? ActivitySession(
            pluginID: pluginID, sessionID: sessionID, source: source, state: update.state,
            label: update.label, title: "", pid: nil, cwd: "", lastUpdated: Date()
        )
        session.state = update.state
        session.label = update.label
        if let title = update.title { session.title = title }
        if let pid = update.pid { session.pid = pid }
        if let cwd = update.cwd { session.cwd = cwd }
        session.lastUpdated = Date()
        sessions[key] = session

        if source != .managed { evictExcessExplicitSessions(keeping: key) }
        recomputeActive()

        Log.plugins.notice("session \(key, privacy: .public) -> \(update.state.rawValue, privacy: .public)")

        // A managed twin hidden by an explicit report must not alert over it.
        let isVisible = ActivityRules.visible(Array(sessions.values), now: Date()).contains { $0.key == key }
        if isVisible, ActivityRules.shouldAlert(requested: update.alert, previous: previous?.state, new: update.state) {
            triggerAlert(alert(for: session, state: session.state), autoDismissAfter: ActivityRules.alertDuration(for: session.state))
            if session.state == .waitingUser { NSSound.beep() }
        } else if update.state == .working, isShowingAlert,
                  currentAlert?.state.isWaiting == true, currentAlert?.sessionKey == key {
            // The user answered, or the subagent finished: the reply banner is stale.
            dismissAlert()
        }
    }

    private func end(_ key: String, alert: Bool) {
        // A managed twin hidden by an explicit report stays hidden until it ends, so its end is hidden too.
        let wasVisible = ActivityRules.visible(Array(sessions.values), now: Date()).contains { $0.key == key }
        guard let session = sessions.removeValue(forKey: key) else { return }
        Log.plugins.notice("session \(key, privacy: .public) ended")
        recomputeActive()
        if alert, wasVisible {
            triggerAlert(self.alert(for: session, state: .completed), autoDismissAfter: ActivityRules.alertDuration(for: .completed))
        } else if currentAlert?.sessionKey == key {
            dismissAlert()
        }
    }

    /// A session without an id continues this plugin's most recent session of
    /// the same label. Dictionary order is arbitrary, so pick by recency.
    private func continuedSessionID(label: String, pluginID: String) -> String {
        sessions.values
            .filter { $0.pluginID == pluginID && $0.label.caseInsensitiveCompare(label) == .orderedSame }
            .max(by: { $0.lastUpdated < $1.lastUpdated })?
            .sessionID ?? "default-\(label)"
    }

    private func alert(for session: ActivitySession, state: ActivityState) -> ActivityAlert {
        ActivityAlert(sessionKey: session.key, label: session.label, state: state, title: session.title, pid: session.pid, timestamp: Date())
    }

    // MARK: - Removal

    func removeSessions(of pluginID: String) {
        removeSessions { $0.pluginID == pluginID }
    }

    func removeSessions(from sources: Set<ActivitySource>) {
        removeSessions { sources.contains($0.source) }
    }

    private func removeSessions(where shouldRemove: (ActivitySession) -> Bool) {
        let keys = sessions.values.filter(shouldRemove).map(\.key)
        guard !keys.isEmpty else { return }
        for key in keys { sessions.removeValue(forKey: key) }
        if let alertKey = currentAlert?.sessionKey, keys.contains(alertKey) { dismissAlert() }
        recomputeActive()
    }

    private func evictExcessExplicitSessions(keeping keep: String) {
        let explicit = sessions.values.filter { $0.source != .managed && $0.key != keep }
        let excess = explicit.count + 1 - NotchConfiguration.activityMaxExplicitSessions
        guard excess > 0 else { return }
        let doomed = Set(explicit.sorted { $0.lastUpdated < $1.lastUpdated }.prefix(excess).map(\.key))
        removeSessions { doomed.contains($0.key) }
    }

    /// Explicit sessions have no process-exit signal of their own. A dead pid,
    /// a finished turn, or a reporter that went silent must not pin the island.
    /// Managed sessions belong to their plugin, which ends them itself.
    private func prune() {
        let now = Date()
        removeSessions { session in
            guard session.source != .managed else { return false }
            let dead = session.pid.flatMap { pid_t(exactly: $0) }.map { !ActivityFocus.isProcessAlive($0) } ?? false
            let idle = now.timeIntervalSince(session.lastUpdated)
            return dead
                || (session.state == .completed && idle > Self.completedSessionLimit)
                || idle > NotchConfiguration.activityInactivityTimeout
        }
        recomputeActive()
    }

    private func recomputeActive() {
        activeSession = ActivityRules.active(ActivityRules.visible(Array(sessions.values), now: Date()))
    }

    // MARK: - Alert

    func triggerAlert(_ alert: ActivityAlert, autoDismissAfter seconds: TimeInterval? = nil) {
        currentAlert = alert
        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
            isShowingAlert = true
        }
        dismissTimer?.invalidate()
        if let seconds {
            dismissTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.dismissAlert() }
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

    func focusActiveSession() {
        guard let session = activeSession else { return }
        dismissAlert()
        ActivityFocus.focus(pid: session.pid)
    }
}
