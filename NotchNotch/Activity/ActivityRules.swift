//
//  ActivityRules.swift
//  NotchNotch
//
//  Which sessions show, which one the island follows, and when to alert.
//  Pure, so `.temp/` scripts can compile it.
//

import Foundation

nonisolated enum ActivitySource: Sendable, Equatable {
    case managed    // a plugin the core launched (inferred state)
    case external   // a registered external plugin over HTTP (reported state)
    case http       // a body without `plugin`: hook scripts, curl
}

nonisolated struct ActivitySession: Identifiable, Equatable, Sendable {
    let pluginID: String
    let sessionID: String
    let source: ActivitySource
    var state: ActivityState
    var label: String
    var title: String
    var pid: Int?
    var cwd: String
    var lastUpdated: Date

    var key: String { ActivityRules.key(pluginID: pluginID, sessionID: sessionID) }
    var id: String { key }
}

nonisolated enum ActivityRules {

    /// How long an explicit report keeps a scanned twin of the same process hidden.
    static let explicitHold: TimeInterval = 180

    /// Namespaced so one plugin can never overwrite another's sessions.
    static func key(pluginID: String, sessionID: String) -> String {
        "\(pluginID)/\(sessionID)"
    }

    /// A managed session is hidden while an external or HTTP session reports
    /// the same pid and was updated within `explicitHold`: the report is exact,
    /// the scan is a guess, and a frozen guess would outrank it (REPLY over BUSY).
    static func visible(_ sessions: [ActivitySession], now: Date) -> [ActivitySession] {
        let explicitPIDs = Set(sessions.compactMap { session -> Int? in
            guard session.source != .managed, now.timeIntervalSince(session.lastUpdated) < explicitHold else { return nil }
            return session.pid
        })
        return sessions.filter { session in
            guard session.source == .managed, let pid = session.pid else { return true }
            return !explicitPIDs.contains(pid)
        }
    }

    /// Highest-priority state wins; within a state the most recent update.
    /// The key breaks ties, so the pick never flickers between equal sessions.
    static func active(_ sessions: [ActivitySession]) -> ActivitySession? {
        let byRecency = sessions.sorted {
            $0.lastUpdated != $1.lastUpdated ? $0.lastUpdated > $1.lastUpdated : $0.key < $1.key
        }
        for state in [ActivityState.waitingUser, .waitingSubagent, .working, .completed] {
            if let match = byRecency.first(where: { $0.state == state }) { return match }
        }
        return byRecency.first
    }

    /// Plugins decide for themselves. Legacy bodies (`requested == nil`) alert
    /// on a transition only, so a hook repeating a state never re-beeps.
    static func shouldAlert(requested: Bool?, previous: ActivityState?, new: ActivityState) -> Bool {
        if let requested { return requested }
        switch new {
        case .waitingUser: return previous != .waitingUser
        case .waitingSubagent: return previous != .waitingSubagent
        case .completed: return previous == .working || previous?.isWaiting == true
        case .working, .idle: return false
        }
    }

    static func alertDuration(for state: ActivityState) -> TimeInterval {
        state == .waitingUser ? 7.0 : 3.5
    }
}
