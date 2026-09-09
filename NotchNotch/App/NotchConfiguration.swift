//
//  NotchConfiguration.swift
//  NotchNotch
//
//  Every tunable number in one place. Phase 1 deliberately keeps these as
//  compile-time constants; when there is a settings UI these become the backing
//  store for it.
//

import SwiftUI

nonisolated enum NotchConfiguration {

    // MARK: - Sizing

    /// Size of the expanded panel's *visible* black body.
    static let expandedSize = CGSize(width: 560, height: 180)

    /// Width of the stand-in notch used on Macs without a camera housing.
    /// ~200pt is roughly the real thing on a 14"/16" MacBook Pro, so the two
    /// code paths feel the same while developing on an external display.
    static let simulatedNotchWidth: CGFloat = 200

    /// The window is bigger than the visible panel on purpose — see
    /// `NotchLayout.windowFrame`. This is the slack around it.
    static let canvasHorizontalPadding: CGFloat = 24
    static let canvasBottomPadding: CGFloat = 24

    // MARK: - Corner radii (animated between states)

    static let collapsedTopCornerRadius: CGFloat = 6
    static let collapsedBottomCornerRadius: CGFloat = 10
    static let expandedTopCornerRadius: CGFloat = 12
    static let expandedBottomCornerRadius: CGFloat = 26

    // MARK: - Hit testing

    /// Extra slop around the notch so the cursor triggers easily and reliably.
    /// Extended horizontally by 40pt on each side, and downwards by 60pt below the notch.
    static let hoverEnterHorizontalMargin: CGFloat = 40
    static let hoverEnterVerticalMargin: CGFloat = 60

    /// Slop around the *expanded* panel. Deliberately larger than the enter
    /// margin: this is the hysteresis that stops the panel flickering when the
    /// cursor grazes the boundary.
    static let hoverExitMargin: CGFloat = 30

    // MARK: - Timing

    /// How long the cursor must stay outside the panel before we start closing.
    /// Without this, a single stray mouse-moved event on the edge collapses the
    /// panel mid-interaction.
    static let collapseDelay: Duration = .milliseconds(220)

    /// Roughly how long the spring takes to settle. Springs have no true
    /// duration, so these are the "close enough" values that drive the
    /// expanding → expanded and collapsing → collapsed transitions.
    static let expandSettleDuration: Duration = .milliseconds(360)
    static let collapseSettleDuration: Duration = .milliseconds(320)

    static let expandAnimation = Animation.spring(response: 0.34, dampingFraction: 0.78)
    static let collapseAnimation = Animation.spring(response: 0.30, dampingFraction: 0.90)

    /// High-frequency pointer polling interval (~30Hz) so mouse movements across
    /// the notch boundary are caught immediately without lag or missed frames.
    static let pointerPollInterval: Duration = .milliseconds(35)

    /// Artwork is not in the first info dictionary after a track change; this is
    /// how long we wait before asking again. See MediaRemoteNowPlayingSource.
    static let artworkRetryDelay: Duration = .milliseconds(250)

    /// How often the Spotify backend re-reads state. The view extrapolates the
    /// playhead between polls, so this only needs to be often enough to catch
    /// track changes and seeks — not to animate the progress bar.
    static let spotifyPollInterval: Duration = .seconds(2)

    /// How often the Accessibility backend re-reads Control Center. It is a
    /// cross-process round trip, so this stays deliberately lazy.
    static let accessibilityPollInterval: Duration = .seconds(2)

    /// Slower still while we are just waiting for the user to grant access.
    static let accessibilityAuthorizationPollInterval: Duration = .seconds(3)

    // MARK: - Private API

    /// Off by default. Flip to `true` to route the window level through
    /// SkyLight SPI (see `PrivateAPI/PrivateWindowElevation.swift`) instead of
    /// `NSWindow.level`. Only needed if the public path turns out not to clear
    /// some full-screen app on your setup.
    static let usesPrivateWindowElevation = false
}
