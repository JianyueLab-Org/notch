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
    static let expandedSize = CGSize(width: 630, height: 174)

    /// Height of the tab-content row inside the expanded panel.
    ///
    /// The vertical budget is exact and must stay that way:
    ///   7 (top pad) + 26 (top bar) + 7 (spacing) + this + 14 (bottom pad)
    ///   == expandedSize.height
    ///
    /// GOTCHA: `.frame(height:)` does NOT clip — a card whose content cannot
    /// compress to this height renders at its own minimum, *centred* on the
    /// slot, and bleeds out of both ends of the panel. Because every tab lives
    /// in the same ZStack, an oversized card breaks the layout of the other
    /// tabs too, even while it is the hidden one. Every tab card must fit here.
    static let expandedContentRowHeight: CGFloat = 120

    /// Additional width in compact (collapsed) state to reveal dynamic indicators flanking the notch.
    static let compactWidthExtension: CGFloat = 72

    /// Width of ear wings shown during HUD alert banners (agent alert, schedule alert, volume/brightness HUD).
    static let hudEarWidth: CGFloat = 150

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
    static let expandedTopCornerRadius: CGFloat = 10
    static let expandedBottomCornerRadius: CGFloat = 18

    // MARK: - Hit testing

    /// Side slop for a file drag only. Ordinary hover is flush with the
    /// collapsed body: the housing meets the menu bar, and slop there opens
    /// the panel while the cursor is still on a menu-bar item.
    static let fileDragEnterHorizontalMargin: CGFloat = 16

    /// Raises the bottom of the no-drag hover region into the housing.
    /// The housing is the full menu-bar band, and a margin below that band was
    /// opening the panel while the cursor was still under the notch.
    static let hoverEnterBottomInset: CGFloat = 12

    /// How far below the bottom of the notch a file drag is still caught.
    /// Measured from the housing, not from the hover region above.
    static let fileDragEnterDepth: CGFloat = 84

    /// Slop around the *expanded* panel. Deliberately larger than the enter
    /// margin: this is the hysteresis that stops the panel flickering when the
    /// cursor grazes the boundary.
    static let hoverExitMargin: CGFloat = 24

    // MARK: - Timing

    /// Dwell delay requiring pointer to stay in trigger area before opening.
    /// 35ms provides instantaneous responsiveness to intentional hovers while
    /// filtering out high-speed cursor passes across the screen top.
    static let hoverExpandDwellDelay: Duration = .milliseconds(35)

    /// How long the cursor must stay outside the panel before we start closing.
    static let collapseDelay: Duration = .milliseconds(180)

    /// Roughly how long the spring takes to settle.
    static let expandSettleDuration: Duration = .milliseconds(290)
    static let collapseSettleDuration: Duration = .milliseconds(220)

    static let expandAnimation = Animation.spring(response: 0.29, dampingFraction: 0.86)
    static let collapseAnimation = Animation.spring(response: 0.22, dampingFraction: 0.92)

    /// High-frequency pointer polling interval (~40Hz) for ultra-fluid boundary catching.
    static let pointerPollInterval: Duration = .milliseconds(25)

    /// Artwork is not in the first info dictionary after a track change; this is
    /// how long we wait before asking again. See MediaRemoteNowPlayingSource.
    static let artworkRetryDelay: Duration = .milliseconds(250)

    /// Retries per track before accepting that MediaRemote has no artwork bytes.
    static let artworkRetryLimit = 4

    /// How long a MediaRemote read waits for its callback before giving up.
    static let mediaRemoteReplyTimeout: Duration = .seconds(2)

    /// AppleScript `with timeout` for the Spotify/Music backends, in seconds.
    static let appleScriptTimeoutSeconds = 3

    /// Delay after a brightness key before reading the new level for the HUD.
    static let brightnessKeyReadDelay: Duration = .milliseconds(80)

    /// How often the Spotify backend re-reads state. The view extrapolates the
    /// playhead between polls, so this only needs to be often enough to catch
    /// track changes and seeks — not to animate the progress bar.
    static let spotifyPollInterval: Duration = .seconds(2)

    /// How often the Accessibility backend re-reads Control Center. It is a
    /// cross-process round trip, so this stays deliberately lazy.
    static let accessibilityPollInterval: Duration = .seconds(2)

    /// Slower still while we are just waiting for the user to grant access.
    static let accessibilityAuthorizationPollInterval: Duration = .seconds(3)

    // MARK: - Clipboard & Shelf

    /// Larger copies are not recorded: every copy rewrites the whole history file.
    static let clipboardMaxItemBytes = 256 * 1024

    /// Oldest staged files are dropped beyond this.
    static let shelfMaxItems = 30

    // MARK: - Agent harness

    /// A hook session with no event for this long is dropped, live pid or not.
    /// An interrupted agent sends no Stop; process scanning takes over from here.
    static let agentHookInactivityTimeout: TimeInterval = 15 * 60

    /// Oldest hook sessions are evicted beyond this.
    static let agentMaxHookSessions = 32

    /// A connection that has not delivered a full request by then is closed.
    static let agentHTTPRequestTimeout: TimeInterval = 5

    /// Further connections are refused while this many are open.
    static let agentHTTPMaxConnections = 16

    // MARK: - Private API

    /// Off by default. Flip to `true` to route the window level through
    /// SkyLight SPI (see `PrivateAPI/PrivateWindowElevation.swift`) instead of
    /// `NSWindow.level`. Only needed if the public path turns out not to clear
    /// some full-screen app on your setup.
    static let usesPrivateWindowElevation = false
}
