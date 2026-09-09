//
//  NotchLayout.swift
//  NotchNotch
//
//  Pure geometry: turns a `NotchGeometry` into every rect the rest of the app
//  needs. No AppKit state, no side effects — which makes it the easy piece to
//  unit test when Phase 2 starts adding content that changes the panel size.
//

import AppKit

nonisolated struct NotchLayout: Equatable, Sendable {

    var geometry: NotchGeometry

    /// Visible size of the black body when closed — exactly the notch, so on a
    /// real MacBook the collapsed state is invisible (it merges with the
    /// housing) and on other Macs it reads as a small pill.
    var collapsedSize: CGSize

    /// Visible size of the black body when open.
    var expandedSize: CGSize

    /// The NSWindow frame. See the note in `init` for why this never changes.
    var windowFrame: CGRect

    /// Cursor must enter this to open the panel.
    var enterRegion: CGRect

    /// Cursor must leave this to close it again.
    var exitRegion: CGRect

    /// The *visible* black body in screen coordinates, per state. These are
    /// what decide whether a click belongs to us — see `acceptsClick(at:in:)`.
    var collapsedBodyRect: CGRect
    var expandedBodyRect: CGRect
    var hasLiveActivity: Bool

    init(geometry: NotchGeometry, hasLiveActivity: Bool = false) {
        self.geometry = geometry
        self.hasLiveActivity = hasLiveActivity

        let notch = geometry.notchRect
        let screen = geometry.screenFrame

        let widthExtension = hasLiveActivity ? NotchConfiguration.compactWidthExtension : 0
        collapsedSize = CGSize(width: notch.width + widthExtension,
                               height: notch.height)
        expandedSize = CGSize(width: max(NotchConfiguration.expandedSize.width, notch.width + 160),
                              height: NotchConfiguration.expandedSize.height)

        // GOTCHA: the window is sized for the *expanded* panel and is never
        // resized afterwards. Growing an NSWindow frame every frame fights
        // SwiftUI's own animation (two animators, two clocks) and reads as
        // stutter — plus a live-resizing borderless window drops frames on
        // Intel Macs. Instead the window is a fixed transparent canvas and only
        // the SwiftUI shape inside it animates. The cost of that choice is that
        // a big invisible window sits over the menu bar, which is exactly why
        // `ignoresMouseEvents` has to be toggled (see NotchOverlayWindow).
        let windowSize = CGSize(width: expandedSize.width + 2 * NotchConfiguration.canvasHorizontalPadding,
                                height: expandedSize.height + NotchConfiguration.canvasBottomPadding)

        // Centre on the notch, pin to the top of the display, and clamp so a
        // notch near a screen edge cannot push the window off-screen.
        let unclampedX = notch.midX - windowSize.width / 2
        let x = min(max(unclampedX, screen.minX), screen.maxX - windowSize.width)
        windowFrame = CGRect(x: x,
                             y: screen.maxY - windowSize.height,
                             width: windowSize.width,
                             height: windowSize.height)

        // Collapsed body: notch plus compact dynamic indicator wings.
        collapsedBodyRect = CGRect(x: notch.midX - collapsedSize.width / 2,
                                   y: notch.minY,
                                   width: collapsedSize.width,
                                   height: collapsedSize.height)

        // Enter region: snugly surrounds the collapsed body with minimal margin
        // (16pt horizontal, 12pt downwards) so casual mouse movement near the top
        // does not trigger accidental openings.
        let hm = NotchConfiguration.hoverEnterHorizontalMargin
        let vm = NotchConfiguration.hoverEnterVerticalMargin
        enterRegion = CGRect(x: collapsedBodyRect.minX - hm,
                             y: collapsedBodyRect.minY - vm,
                             width: collapsedBodyRect.width + 2 * hm,
                             height: collapsedBodyRect.height + vm + 30)
        expandedBodyRect = CGRect(x: notch.midX - expandedSize.width / 2,
                                  y: screen.maxY - expandedSize.height,
                                  width: expandedSize.width,
                                  height: expandedSize.height)
        exitRegion = CGRect(x: expandedBodyRect.minX - NotchConfiguration.hoverExitMargin,
                            y: expandedBodyRect.minY - NotchConfiguration.hoverExitMargin,
                            width: expandedBodyRect.width + 2 * NotchConfiguration.hoverExitMargin,
                            height: expandedBodyRect.height + NotchConfiguration.hoverExitMargin + 50)
    }

    /// Should the overlay window accept a click with the cursor at `point`?
    ///
    /// GOTCHA — the reason this exists at all. The window is much larger than
    /// the visible body (it is sized once for the expanded panel and never
    /// resized), and macOS does **not** pass clicks through the transparent
    /// pixels of a non-opaque window: with `ignoresMouseEvents == false` the
    /// window server hands us every click in the whole window rect, empty
    /// canvas included, and the app underneath never sees it. Overriding
    /// `hitTest(_:)` does not help either — by then the event has already been
    /// taken away from the other app; returning nil just swallows it.
    ///
    /// So `ignoresMouseEvents` is the only real lever, and it has to follow the
    /// cursor rather than the state: interactive only while the pointer is
    /// actually over the painted body. Mouse-down is always preceded by a
    /// mouse-moved to the same point, so the flag is already correct by the
    /// time the click arrives.
    func acceptsClick(at point: CGPoint, in state: NotchState) -> Bool {
        guard state != .collapsed else { return false }
        let body = state.isVisiblyExpanded ? expandedBodyRect : collapsedBodyRect
        return body.insetBy(dx: -4, dy: -4).contains(point)
    }
}
