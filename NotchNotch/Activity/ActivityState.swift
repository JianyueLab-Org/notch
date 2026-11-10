//
//  ActivityState.swift
//  NotchNotch
//
//  The session states every plugin reports. Pure, so `.temp/` scripts can
//  compile it; colours and labels live in ActivityState+Presentation.swift.
//

import Foundation

nonisolated enum ActivityState: String, Sendable, Equatable, CaseIterable {
    case working
    case waitingUser       // needs a human reply: permission, question, prompt
    case waitingSubagent   // waiting on a delegated child task
    case completed         // finished a turn or a task
    case idle

    var isWaiting: Bool {
        self == .waitingUser || self == .waitingSubagent
    }
}
