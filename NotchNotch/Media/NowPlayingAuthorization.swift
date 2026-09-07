//
//  NowPlayingAuthorization.swift
//  NotchNotch
//
//  Not every backend needs permission — MediaRemote needs none (it just
//  refuses to answer), the Accessibility one does. The panel needs to tell
//  those two failure modes apart so it can show a useful empty state.
//

import Foundation

nonisolated enum NowPlayingAuthorization: Equatable, Sendable {
    /// Backend works without asking the user for anything.
    case notRequired
    /// Permission granted; data should be flowing.
    case granted
    /// The user has to grant something in System Settings before this works.
    /// The payload is what to tell them.
    case needsPermission(String)

    /// True when this backend cannot produce anything until the user acts.
    /// Lets call sites branch without matching the associated value.
    var isBlocked: Bool {
        if case .needsPermission = self { true } else { false }
    }
}
