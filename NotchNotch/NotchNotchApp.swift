//
//  NotchNotchApp.swift
//  NotchNotch
//
//  Created by Jianyue Hugo Liang on 03/09/2026.
//

import SwiftUI

@main
struct NotchNotchApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // MenuBarExtra (macOS 13+) is the app's only scene. An agent app needs
        // *some* scene to be a valid SwiftUI App, and this one doubles as the
        // required status-bar presence — no NSStatusItem bookkeeping needed.
        // The overlay itself is a hand-built NSWindow, not a scene, because
        // nothing in SwiftUI's scene vocabulary produces a borderless
        // click-through panel above the menu bar.
        MenuBarExtra("NotchNotch", systemImage: "menubar.rectangle") {
            Button("Toggle Notch Panel") {
                appDelegate.notchController?.toggle()
            }
            .keyboardShortcut("t")
            Divider()
            Button("Settings…") {
                SettingsWindowController.shared.show()
            }
            .keyboardShortcut(",")
            Divider()
            Button("Re-detect Notch") {
                appDelegate.notchController?.reload()
            }
            Divider()
            Button("Quit NotchNotch") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
