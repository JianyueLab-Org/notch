//
//  RestartPolicy.swift
//  NotchNotch
//
//  Backoff for a managed plugin that exits. Pure, so `.temp/` scripts can
//  compile it.
//

import Foundation

nonisolated struct RestartPolicy: Sendable {
    enum Decision: Equatable, Sendable {
        case restart(after: TimeInterval)
        case crashed
    }

    static let delays: [TimeInterval] = [1, 2, 4, 8, 16, 30]
    static let maxExits = 5
    static let window: TimeInterval = 600

    private var exits: [Date] = []

    /// A plugin that keeps dying stops being restarted until it is re-enabled;
    /// otherwise a broken binary would spin forever.
    mutating func recordExit(at now: Date) -> Decision {
        exits = exits.filter { now.timeIntervalSince($0) < Self.window } + [now]
        if exits.count >= Self.maxExits { return .crashed }
        return .restart(after: Self.delays[min(exits.count - 1, Self.delays.count - 1)])
    }
}
