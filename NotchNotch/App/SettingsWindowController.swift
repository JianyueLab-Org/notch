//
//  SettingsWindowController.swift
//  NotchNotch
//

import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    override private init() {
        super.init()
    }

    func show() {
        if let win = window {
            if !win.isVisible {
                win.center()
            }
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentView = SettingsView()
        let hostingController = NSHostingController(rootView: contentView)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        win.title = "NotchNotch 设置"
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.contentViewController = hostingController
        win.backgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1.0)
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()

        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // Window remains allocated for quick re-display
    }
}
