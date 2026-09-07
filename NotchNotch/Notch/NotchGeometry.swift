//
//  NotchGeometry.swift
//  NotchNotch
//
//  Figuring out where the notch actually is.
//
//  COORDINATE SYSTEM GOTCHA: everything in this file is in AppKit *screen*
//  coordinates — one global space shared by all displays, origin at the
//  bottom-left of the primary screen, +Y pointing up. That is the same space
//  `NSScreen.frame`, `NSWindow.setFrame(_:display:)` and `NSEvent.mouseLocation`
//  all use, so we never have to flip anything. SwiftUI's top-left/+Y-down space
//  only appears once we are *inside* the hosting view.
//

import AppKit
import OSLog

/// Which detection path produced a `NotchGeometry`.
nonisolated enum NotchGeometrySource: String, Equatable, Sendable {
    /// A real camera housing, measured from `safeAreaInsets` + `auxiliaryTop*Area`.
    case hardware
    /// No notch on this display: a centred strip the height of the menu bar.
    case simulated
}

nonisolated struct NotchGeometry: Equatable, Sendable {
    /// The notch (or its stand-in) in screen coordinates.
    var notchRect: CGRect
    /// The full frame of the display the notch belongs to.
    var screenFrame: CGRect
    var source: NotchGeometrySource
    var screenName: String
}

extension NotchGeometry {

    /// The display we should attach the overlay to.
    ///
    /// `NSScreen.main` means "the screen with the key window", which for a
    /// background agent with no windows is not what we want. Prefer whichever
    /// display actually has a notch; otherwise fall back to the one carrying
    /// the menu bar (`NSScreen.screens.first`).
    @MainActor
    static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first(where: { $0.hasHardwareNotch })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    @MainActor
    static func detect(on screen: NSScreen) -> NotchGeometry {
        let frame = screen.frame
        let name = screen.localizedName

        // --- Path 1: real hardware notch -------------------------------------
        //
        // `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` are the two unobscured
        // strips of menu bar either side of the camera housing. They are declared
        // as plain `NSRect` in the ObjC header but marked SwiftPrivate, so AppKit's
        // Swift overlay re-exposes them as `NSRect?` — nil (rather than
        // `NSZeroRect`) when the display has no housing. That makes them a far
        // better notch probe than `safeAreaInsets` alone, which is also non-zero
        // on some non-notched configurations.
        //
        // The notch is exactly the gap *between* those two rects, and its height
        // is the top safe-area inset.
        let insetTop = screen.safeAreaInsets.top
        if insetTop > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea,
           right.minX > left.maxX {

            let rect = CGRect(x: left.maxX,
                              y: frame.maxY - insetTop,
                              width: right.minX - left.maxX,
                              height: insetTop)

            // Sanity check before trusting it. If a future OS ever reports these
            // in a different space, we would rather draw a sane simulated notch
            // than park the window off-screen.
            if frame.contains(rect) {
                Log.geometry.notice("""
                    notch: hardware path on \(name, privacy: .public) — \
                    rect \(NSStringFromRect(rect), privacy: .public), \
                    screen \(NSStringFromRect(frame), privacy: .public)
                    """)
                return NotchGeometry(notchRect: rect,
                                     screenFrame: frame,
                                     source: .hardware,
                                     screenName: name)
            }

            Log.geometry.error("""
                notch: auxiliary areas gave \(NSStringFromRect(rect), privacy: .public) which is \
                outside screen \(NSStringFromRect(frame), privacy: .public) — falling back to simulated
                """)
        }

        // --- Path 2: simulated -----------------------------------------------
        //
        // `NSStatusBar.system.thickness` is the menu bar height (24pt at 1x), so
        // the stand-in occupies exactly the same band a real notch would.
        let height = NSStatusBar.system.thickness
        let width = min(NotchConfiguration.simulatedNotchWidth, frame.width)
        let rect = CGRect(x: frame.midX - width / 2,
                          y: frame.maxY - height,
                          width: width,
                          height: height)

        Log.geometry.notice("""
            notch: simulated path on \(name, privacy: .public) (no camera housing) — \
            rect \(NSStringFromRect(rect), privacy: .public), \
            screen \(NSStringFromRect(frame), privacy: .public)
            """)
        return NotchGeometry(notchRect: rect,
                             screenFrame: frame,
                             source: .simulated,
                             screenName: name)
    }
}

extension NSScreen {
    /// True when this display has a camera housing carved out of the menu bar.
    var hasHardwareNotch: Bool {
        safeAreaInsets.top > 0 && auxiliaryTopLeftArea != nil && auxiliaryTopRightArea != nil
    }
}
