//
//  SystemMediaHUDController.swift
//  NotchNotch
//
//  Monitors and controls system audio volume and display brightness.
//  Presents a compact notch HUD bar when volume or brightness is adjusted.
//

import AppKit
import AudioToolbox
import Combine
import CoreAudio
import Foundation
import OSLog
import SwiftUI

enum SystemHUDType: String, Equatable {
    case volume
    case brightness
}

private typealias DisplayServicesGetBrightnessType = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
private typealias DisplayServicesSetBrightnessType = @convention(c) (CGDirectDisplayID, Float) -> Int32

@MainActor
final class SystemMediaHUDController: ObservableObject {

    static let shared = SystemMediaHUDController()

    @Published var isShowing: Bool = false
    @Published var currentType: SystemHUDType = .volume
    @Published var volume: Float = 0.5
    @Published var isMuted: Bool = false
    @Published var brightness: Float = 0.75

    private var dismissTimer: Timer?
    private var hasInitialized: Bool = false

    private var brightnessKeyMonitors: [Any] = []
    private var brightnessReadTask: Task<Void, Never>?

    private var getBrightnessFn: DisplayServicesGetBrightnessType?
    private var setBrightnessFn: DisplayServicesSetBrightnessType?

    private var defaultAudioDeviceID: AudioDeviceID = 0
    /// Every listener installed on an output device, kept so the exact same
    /// block can be removed from that device when the default changes —
    /// CoreAudio matches listeners by block identity.
    private var deviceListeners: [(device: AudioDeviceID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []

    var displayPercentage: Int {
        let val = currentType == .volume ? volume : brightness
        return max(0, min(100, Int(round(val * 100))))
    }

    var hudTitle: String {
        currentType == .volume ? "Volume" : "Brightness"
    }

    var hudIcon: String {
        switch currentType {
        case .volume:
            if isMuted {
                return "speaker.slash.fill"
            } else if volume <= 0.01 {
                return "speaker.fill"
            } else if volume < 0.33 {
                return "speaker.wave.1.fill"
            } else if volume < 0.66 {
                return "speaker.wave.2.fill"
            } else {
                return "speaker.wave.3.fill"
            }
        case .brightness:
            if brightness < 0.35 {
                return "sun.min.fill"
            } else {
                return "sun.max.fill"
            }
        }
    }

    init() {
        setupDisplayServices()
        setupAudioMonitoring()
        readCurrentValues()

        installBrightnessKeyMonitors()

        // Enable HUD display after brief startup grace period
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.hasInitialized = true
        }
    }

    // MARK: - DisplayServices Setup

    private func setupDisplayServices() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW) else {
            Log.lifecycle.error("Failed to load DisplayServices framework")
            return
        }

        if let getSym = dlsym(handle, "DisplayServicesGetBrightness") {
            getBrightnessFn = unsafeBitCast(getSym, to: DisplayServicesGetBrightnessType.self)
        }
        if let setSym = dlsym(handle, "DisplayServicesSetBrightness") {
            setBrightnessFn = unsafeBitCast(setSym, to: DisplayServicesSetBrightnessType.self)
        }
    }

    // MARK: - Audio Monitoring Setup

    private func setupAudioMonitoring() {
        updateDefaultAudioDevice()

        var defaultDeviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        _ = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultDeviceAddress,
            DispatchQueue.main
        ) { [weak self] _, _ in
            Task { @MainActor in
                self?.updateDefaultAudioDevice()
                self?.readVolume()
            }
        }
    }

    private func updateDefaultAudioDevice() {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout.size(ofValue: deviceID))
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )

        if status == 0, deviceID != defaultAudioDeviceID {
            defaultAudioDeviceID = deviceID
            installVolumeListener()
        }
    }

    /// Idempotent: drops whatever was installed on the previous device first,
    /// so a device switch never leaves listeners behind or doubles them up.
    private func installVolumeListener() {
        removeVolumeListeners()
        guard defaultAudioDeviceID != 0 else { return }

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                self?.handleVolumeChanged()
            }
        }
        for var address in volumeAddresses() + [Self.muteAddress] where AudioObjectHasProperty(defaultAudioDeviceID, &address) {
            if AudioObjectAddPropertyListenerBlock(defaultAudioDeviceID, &address, DispatchQueue.main, block) == noErr {
                deviceListeners.append((defaultAudioDeviceID, address, block))
            }
        }
    }

    private func removeVolumeListeners() {
        // Removes from the device each listener was added to, which is the
        // previous default by the time a device switch calls this.
        for (device, address, block) in deviceListeners {
            var address = address
            _ = AudioObjectRemovePropertyListenerBlock(device, &address, DispatchQueue.main, block)
        }
        deviceListeners.removeAll()
    }

    // MARK: - Volume addresses

    private static let muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    private static func volumeScalarAddress(element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
    }

    /// Where this device's volume lives, best first. The virtual main volume
    /// is what the system volume keys drive and covers devices that only have
    /// per-channel volume; the main element and then the stereo channels are
    /// the fallbacks for devices that do not publish it.
    private func volumeAddresses() -> [AudioObjectPropertyAddress] {
        let device = defaultAudioDeviceID
        var virtualMain = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(device, &virtualMain) { return [virtualMain] }
        var main = Self.volumeScalarAddress(element: kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(device, &main) { return [main] }
        return [1, 2].map { Self.volumeScalarAddress(element: $0) }.filter { address in
            var address = address
            return AudioObjectHasProperty(device, &address)
        }
    }

    // MARK: - Reading & Writing

    func readCurrentValues() {
        readVolume()
        readBrightness()
    }

    private func readVolume() {
        guard defaultAudioDeviceID != 0 else { return }

        // Per-channel devices report the average of their channels.
        let levels = volumeAddresses().compactMap { address -> Float32? in
            var address = address
            var vol = Float32(0)
            var size = UInt32(MemoryLayout.size(ofValue: vol))
            let status = AudioObjectGetPropertyData(defaultAudioDeviceID, &address, 0, nil, &size, &vol)
            return status == 0 ? vol : nil
        }
        if !levels.isEmpty {
            self.volume = max(0, min(1.0, levels.reduce(0, +) / Float32(levels.count)))
        }

        var mute: UInt32 = 0
        var muteSize = UInt32(MemoryLayout.size(ofValue: mute))
        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let muteStatus = AudioObjectGetPropertyData(defaultAudioDeviceID, &muteAddress, 0, nil, &muteSize, &mute)
        if muteStatus == 0 {
            self.isMuted = (mute != 0)
        }
    }

    private func readBrightness() {
        guard let getFn = getBrightnessFn else { return }
        var current: Float = 0
        let res = getFn(Self.builtInDisplayID(), &current)
        if res == 0 {
            self.brightness = max(0, min(1.0, current))
        }
    }

    /// Brightness belongs to the built-in panel. `CGMainDisplayID` is the
    /// menu-bar display, which is an external monitor whenever one is set as
    /// main. Falls back to it only on Macs without a built-in display.
    private static func builtInDisplayID() -> CGDirectDisplayID {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return CGMainDisplayID() }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return CGMainDisplayID() }
        return displays.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 } ?? CGMainDisplayID()
    }

    func setVolumeLevel(_ newVolume: Float) {
        let clamped = max(0, min(1.0, newVolume))
        self.volume = clamped

        guard defaultAudioDeviceID != 0 else { return }
        for var address in volumeAddresses() {
            var vol = Float32(clamped)
            let size = UInt32(MemoryLayout.size(ofValue: vol))
            _ = AudioObjectSetPropertyData(defaultAudioDeviceID, &address, 0, nil, size, &vol)
        }
        triggerHUD(type: .volume)
    }

    func setBrightnessLevel(_ newBrightness: Float) {
        let clamped = max(0, min(1.0, newBrightness))
        self.brightness = clamped

        guard let setFn = setBrightnessFn else { return }
        _ = setFn(Self.builtInDisplayID(), clamped)
        triggerHUD(type: .brightness)
    }

    // MARK: - Change Handlers

    private func handleVolumeChanged() {
        let oldVol = self.volume
        let oldMute = self.isMuted
        readVolume()

        if hasInitialized, (abs(oldVol - self.volume) > 0.005 || oldMute != self.isMuted) {
            triggerHUD(type: .volume)
        }
    }

    // MARK: - Brightness keys

    /// NX_KEYTYPE_BRIGHTNESS_UP / _DOWN from IOKit's `ev_keymap.h`.
    private static let brightnessKeyTypes: Set<Int> = [2, 3]
    /// Virtual key codes some keyboards send for brightness instead (F14/F15).
    private static let brightnessKeyCodes: Set<UInt16> = [144, 145]

    /// The brightness HUD answers a brightness key and nothing else. Polling
    /// the level popped it for auto-brightness and idle dimming, which change
    /// the same value without the user asking.
    private func installBrightnessKeyMonitors() {
        let mask: NSEvent.EventTypeMask = [.systemDefined, .keyDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            // AppKit delivers these on the main thread.
            MainActor.assumeIsolated { self?.handleBrightnessKey(event) }
        }) {
            brightnessKeyMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handleBrightnessKey(event) }
            return event
        }) {
            brightnessKeyMonitors.append(local)
        }
    }

    private func handleBrightnessKey(_ event: NSEvent) {
        let isBrightnessKey: Bool
        switch event.type {
        case .systemDefined:
            // Subtype 8 is an IOKit special key; data1 packs the key type in
            // the high word and 0x0A (down) / 0x0B (up) in the next byte.
            guard event.subtype.rawValue == 8 else { return }
            let keyType = (event.data1 & 0xFFFF_0000) >> 16
            let isDown = (event.data1 & 0xFF00) >> 8 == 0x0A
            isBrightnessKey = isDown && Self.brightnessKeyTypes.contains(keyType)
        case .keyDown:
            isBrightnessKey = Self.brightnessKeyCodes.contains(event.keyCode)
        default:
            isBrightnessKey = false
        }
        guard isBrightnessKey, hasInitialized else { return }

        // The system applies the step a moment after the key and eases into
        // it, so read once to show the HUD and again once it has settled.
        brightnessReadTask?.cancel()
        brightnessReadTask = Task { [weak self] in
            try? await Task.sleep(for: NotchConfiguration.brightnessKeyReadDelay)
            guard !Task.isCancelled, let self else { return }
            self.readBrightness()
            self.triggerHUD(type: .brightness)
            try? await Task.sleep(for: NotchConfiguration.brightnessKeyReadDelay * 4)
            guard !Task.isCancelled else { return }
            self.readBrightness()
        }
    }

    // MARK: - HUD Trigger

    func triggerHUD(type: SystemHUDType) {
        currentType = type
        withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
            isShowing = true
        }

        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 1.8, repeats: false) { [weak self] _ in
            Task { @MainActor in
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                    self?.isShowing = false
                }
            }
        }
    }
}
