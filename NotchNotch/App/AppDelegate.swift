//
//  AppDelegate.swift
//  NotchNotch
//

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private(set) var notchController: NotchWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setlinebuf(stdout)
        setlinebuf(stderr)
        print("[AppDelegate] applicationDidFinishLaunching - starting NotchNotch")
        fflush(stdout)

        // `LSUIElement = YES` in Info.plist already makes this an agent app, so
        // this line is belt-and-braces — but it is also the switch to flip if
        // you ever want a real Dock icon while debugging.
        NSApp.setActivationPolicy(.accessory)

        let controller = NotchWindowController()
        controller.start()
        notchController = controller
    }

    func applicationWillTerminate(_ notification: Notification) {
        notchController?.stop()
    }
}
