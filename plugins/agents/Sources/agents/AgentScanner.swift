//
//  AgentScanner.swift
//  NotchNotch agent plugin
//
//  Turns successive ps snapshots into session messages. CPU is the only
//  signal, so "needs input" is a guess: one quiet poll is not enough.
//

import Foundation

enum WireState: String {
    case working
    case waitingUser
}

enum OutgoingMessage: Equatable {
    case update(id: String, state: WireState, label: String, pid: Int, cwd: String?, alert: Bool)
    case end(id: String, alert: Bool)
}

struct AgentScanner {
    static let quietPollsBeforeWaiting = 3
    static let busyCPU = 1.5

    private struct Tracked {
        var state: WireState
        var quietPolls: Int
    }

    private var tracked: [String: Tracked] = [:]

    /// Messages are emitted on change only; an unchanged agent is silent.
    mutating func step(entries: [ProcessRawEntry], cwd: (Int) -> String?) -> [OutgoingMessage] {
        var messages: [OutgoingMessage] = []
        var seen = Set<String>()

        for agent in AgentProcessMatcher.discover(entries) {
            let id = "\(agent.name.lowercased().replacingOccurrences(of: " ", with: "-"))-\(agent.pid)"
            seen.insert(id)
            let usage = AgentProcessMatcher.cpuUsage(of: agent, in: entries)
            var inferred: WireState = (usage.hasActiveTool || usage.total > Self.busyCPU) ? .working : .waitingUser

            guard var session = tracked[id] else {
                tracked[id] = Tracked(state: inferred, quietPolls: 0)
                messages.append(.update(id: id, state: inferred, label: agent.name, pid: agent.pid, cwd: cwd(agent.pid), alert: false))
                continue
            }
            if session.state == .working && inferred == .waitingUser {
                session.quietPolls += 1
                if session.quietPolls < Self.quietPollsBeforeWaiting { inferred = .working }
            } else if inferred == .working {
                session.quietPolls = 0
            }
            if session.state != inferred {
                let alert = session.state == .working && inferred == .waitingUser
                if alert { session.quietPolls = 0 }
                session.state = inferred
                messages.append(.update(id: id, state: inferred, label: agent.name, pid: agent.pid, cwd: nil, alert: alert))
            }
            tracked[id] = session
        }

        // Every tracked agent is working or waiting, so an exit always deserves an alert.
        for id in tracked.keys.sorted() where !seen.contains(id) {
            tracked.removeValue(forKey: id)
            messages.append(.end(id: id, alert: true))
        }
        return messages
    }
}
