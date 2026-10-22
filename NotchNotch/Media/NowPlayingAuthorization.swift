//
//  NowPlayingAuthorization.swift
//  NotchNotch
//
//  Not every backend needs permission — MediaRemote needs none (it just
//  refuses to answer), the Accessibility one does. The panel needs to tell
//  those two failure modes apart so it can show a useful empty state.
//

import Foundation

/// Which System Settings switch the user has to flip. Modelled explicitly so
/// the panel picks its text and Settings pane without parsing a message.
nonisolated enum NowPlayingPermission: Equatable, Sendable {
    case accessibility
    case spotifyAutomation
    case musicAutomation

    var settingsURL: URL? {
        let pane = switch self {
        case .accessibility: "Privacy_Accessibility"
        case .spotifyAutomation, .musicAutomation: "Privacy_Automation"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
    }
}

nonisolated enum NowPlayingAuthorization: Equatable, Sendable {
    /// Backend works without asking the user for anything.
    case notRequired
    /// Permission granted; data should be flowing.
    case granted
    /// The user has to grant something in System Settings before this works.
    case needsPermission(NowPlayingPermission)

    /// True when this backend cannot produce anything until the user acts.
    /// Lets call sites branch without matching the associated value.
    var isBlocked: Bool {
        if case .needsPermission = self { true } else { false }
    }
}
