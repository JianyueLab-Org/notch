//
//  MediaKeyTransport.swift
//  NotchNotch
//
//  Transport control by synthesising the hardware media keys (F7/F8/F9).
//
//  This is deliberately backend-independent: whatever we end up using to *read*
//  now-playing state, this is the most universal way to *control* it — it goes
//  through the same path as the keys on the keyboard, so it reaches whichever
//  app currently owns playback, browsers included.
//
//  Requires Accessibility permission: posting to the HID event tap is exactly
//  what that permission gates. `AXIsProcessTrusted()` must be true or the
//  events are silently dropped — no error, nothing happens. That silence is why
//  the panel surfaces the permission state instead of just looking broken.
//

import AppKit
import OSLog

nonisolated enum MediaKeyTransport {

    /// Values from IOKit's `ev_keymap.h` (NX_KEYTYPE_*). These are the system's
    /// own media key codes, not virtual key codes.
    private enum NXKey: Int32 {
        case play = 16
        case next = 17
        case previous = 18
    }

    @MainActor
    @discardableResult
    static func post(_ command: MediaCommand) -> Bool {
        guard AXIsProcessTrusted() else {
            Log.media.error("media: cannot post media key — Accessibility not granted")
            return false
        }
        let key: NXKey = switch command {
        case .togglePlayPause: .play
        case .nextTrack: .next
        case .previousTrack: .previous
        }
        // A key must be pressed *and* released; sending only the down event
        // leaves some players latched.
        send(key, down: true)
        send(key, down: false)
        Log.media.debug("media: posted media key \(key.rawValue, privacy: .public)")
        return true
    }

    @MainActor
    private static func send(_ key: NXKey, down: Bool) {
        // The system-defined event packs the key code and up/down state into
        // data1; subtype 8 marks it as an IOKit "special key" event.
        let state: Int32 = down ? 0x0A : 0x0B
        let data1 = Int((key.rawValue << 16) | (state << 8))
        guard let event = NSEvent.otherEvent(with: .systemDefined,
                                             location: .zero,
                                             modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state) << 8),
                                             timestamp: 0,
                                             windowNumber: 0,
                                             context: nil,
                                             subtype: 8,
                                             data1: data1,
                                             data2: -1),
              let cgEvent = event.cgEvent else {
            Log.media.error("media: could not construct system-defined media key event")
            return
        }
        cgEvent.post(tap: .cghidEventTap)
    }
}
