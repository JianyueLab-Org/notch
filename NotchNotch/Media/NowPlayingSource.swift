//
//  NowPlayingSource.swift
//  NotchNotch
//
//  The seam between "what is playing" and "how we found out".
//
//  Phase 2 ships one implementation (MediaRemote). An Accessibility-based
//  source — reading Control Center's Now Playing module, which needs the user
//  to grant Accessibility but touches no private framework — is a drop-in:
//  conform to this protocol and change the one line in NotchWindowController
//  that constructs the source.
//

import Foundation

nonisolated enum MediaCommand {
    case togglePlayPause
    case nextTrack
    case previousTrack
}

@MainActor
protocol NowPlayingSource: AnyObject {

    /// False when the backing mechanism is missing or not permitted, so the UI
    /// can say something useful instead of just showing nothing.
    var isAvailable: Bool { get }

    /// Whether this backend needs the user to grant something first, and if so
    /// what to tell them. Lets the panel distinguish "nothing is playing" from
    /// "I am not allowed to look".
    var authorization: NowPlayingAuthorization { get }

    /// Surface the system permission prompt, if this backend needs one.
    func requestAuthorization()

    /// Called on the main actor whenever the track, artwork or transport state
    /// changes. `nil` means nothing is playing anywhere.
    var onChange: ((NowPlaying?) -> Void)? { get set }

    func start()
    func stop()
    func send(_ command: MediaCommand)
}
