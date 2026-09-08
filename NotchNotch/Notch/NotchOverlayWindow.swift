//
//  NotchOverlayWindow.swift
//  NotchNotch
//
//  The borderless, transparent, always-on-top panel the SwiftUI content lives
//  in. All the window-server-facing decisions are here and nowhere else.
//

import AppKit
import OSLog

final class NotchOverlayWindow: NSPanel {

    /// WINDOW LEVEL — why this number.
    ///
    ///   .mainMenu   (24)   the menu bar itself
    ///   .statusBar  (25)   one above it; this is where menu-bar utilities live
    ///   .popUpMenu  (101)  open NSMenus, the volume/brightness HUD
    ///   .screenSaver(1000) the screen saver, and system alerts
    ///
    /// We want to cover the menu bar (otherwise the panel is chopped in half by
    /// it), so `.mainMenu` is out. `.statusBar + 1` puts us above the menu bar
    /// *and* above other status-level panels from other menu-bar utilities,
    /// while still staying under anything the system genuinely owns: an open
    /// menu, the volume HUD, notification banners, the screen saver. Going to
    /// `.screenSaver` "to be safe" is the common mistake — it wins every
    /// argument, including the ones you should lose.
    static let overlayLevel = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)

    init(contentRect: NSRect) {
        // `.nonactivatingPanel` is the whole reason this is an NSPanel and not
        // an NSWindow: clicking the overlay must not pull focus away from
        // whatever the user is actually working in.
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false                 // the SwiftUI shape draws its own
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false      // we keep a strong reference and reuse it
        hidesOnDeactivate = false         // an agent app is never "active"
        animationBehavior = .none         // no AppKit fade fighting our spring
        level = Self.overlayLevel

        // .canJoinAllSpaces  — follow the user across Spaces instead of living in one
        // .stationary        — do not slide around during the Spaces swipe animation
        // .fullScreenAuxiliary — allowed to draw over a full-screen window
        // .ignoresCycle      — stay out of ⌘` window cycling
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        // Ask the window server to keep sending mouse-moved events even though
        // we are usually not the key window. Without this the local monitor
        // goes quiet exactly when the panel is open.
        acceptsMouseMovedEvents = true

        // Start click-through. See `setInteractive(_:)`.
        ignoresMouseEvents = true

        registerForDraggedTypes([.fileURL])

        Log.window.notice("window: created at level \(Self.overlayLevel.rawValue, privacy: .public)")
    }

    /// The window is permanently sized for the *expanded* panel, so most of it
    /// is transparent most of the time — and macOS does NOT pass clicks through
    /// those transparent pixels. Whenever this is interactive, the window server
    /// hands us every click in the whole frame and the app underneath gets
    /// nothing. So the caller keeps this in step with the cursor: interactive
    /// only while the pointer is actually over the painted body.
    /// See `NotchLayout.acceptsClick(at:in:)`.
    func setInteractive(_ interactive: Bool) {
        guard ignoresMouseEvents == interactive else { return }
        ignoresMouseEvents = !interactive
        Log.window.debug("window: ignoresMouseEvents = \(!interactive, privacy: .public)")
    }

    /// A borderless panel refuses key status unless we say otherwise. We allow
    /// it (Phase 2 wants a search field in there) but never main status, and
    /// `.nonactivatingPanel` means taking key does not activate the app.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
