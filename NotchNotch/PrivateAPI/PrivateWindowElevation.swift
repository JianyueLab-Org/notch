//
//  PrivateWindowElevation.swift
//  NotchNotch
//
//  ⚠️  PRIVATE API — THE ONLY FILE IN THE PROJECT THAT TOUCHES SPI  ⚠️
//
//  Nothing here is required for Phase 1: `NSWindow.level` plus
//  `.canJoinAllSpaces / .fullScreenAuxiliary` already puts the overlay over the
//  menu bar and over other apps' full-screen windows. This exists as the escape
//  hatch for the cases where it does not, and it is kept in its own file so it
//  can be deleted in one move if this ever needs to ship on the App Store.
//
//  Two deliberate safety properties:
//
//  1. Symbols are resolved with dlopen/dlsym at runtime, NOT by linking against
//     SkyLight. If Apple renames or removes them the app still launches and this
//     just reports failure — as opposed to dying at dyld time with a missing
//     symbol, which is how most private-API adoption breaks.
//  2. Every entry point returns Bool and logs. No trapping, no force unwraps.
//
//  Gated behind `NotchConfiguration.usesPrivateWindowElevation`, which is false.
//

import AppKit
import OSLog
import Darwin

nonisolated enum PrivateWindowElevation {

    private typealias MainConnectionIDFn = @convention(c) () -> Int32
    private typealias SetWindowLevelFn = @convention(c) (Int32, UInt32, Int32) -> Int32

    // `nonisolated(unsafe)` is honest here: a dlopen handle is resolved once at
    // first use and never mutated, and dlsym on it is thread-safe.
    nonisolated(unsafe) private static let handle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let raw = dlsym(handle, name) else { return nil }
        return unsafeBitCast(raw, to: type)
    }

    /// Pin the window above everything the window server will let us, using
    /// SkyLight's per-connection window level rather than AppKit's.
    ///
    /// Use only if a full-screen app on your machine manages to cover the
    /// overlay despite `.fullScreenAuxiliary`. The public path is preferred
    /// because AppKit keeps re-applying `NSWindow.level` on its own schedule and
    /// will happily stomp on whatever we set here.
    @discardableResult
    @MainActor
    static func elevate(_ window: NSWindow) -> Bool {
        guard window.windowNumber > 0 else {
            Log.privateAPI.error("private: window has no window number yet")
            return false
        }
        guard let mainConnectionID = symbol("SLSMainConnectionID", as: MainConnectionIDFn.self),
              let setWindowLevel = symbol("SLSSetWindowLevel", as: SetWindowLevelFn.self) else {
            Log.privateAPI.error("private: SkyLight symbols unavailable — staying on the public path")
            return false
        }

        let level = CGWindowLevelForKey(.maximumWindow) - 1
        let result = setWindowLevel(mainConnectionID(), UInt32(window.windowNumber), level)
        if result == 0 {
            Log.privateAPI.notice("private: elevated window to SkyLight level \(level, privacy: .public)")
            return true
        }
        Log.privateAPI.error("private: SLSSetWindowLevel failed with \(result, privacy: .public)")
        return false
    }
}
