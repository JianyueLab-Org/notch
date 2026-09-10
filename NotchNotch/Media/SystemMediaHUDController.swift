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
    private var pollTimer: Timer?
    private var hasInitialized: Bool = false

    private var getBrightnessFn: DisplayServicesGetBrightnessType?
    private var setBrightnessFn: DisplayServicesSetBrightnessType?

    private var defaultAudioDeviceID: AudioDeviceID = 0
    private var volumeListenerBlock: AudioObjectPropertyListenerBlock?

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

        // Start background polling for brightness changes
        startBrightnessPolling()

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

        installVolumeListener()
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

    private func installVolumeListener() {
        guard defaultAudioDeviceID != 0 else { return }

        var volAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                self?.handleVolumeChanged()
            }
        }
        self.volumeListenerBlock = block

        _ = AudioObjectAddPropertyListenerBlock(
            defaultAudioDeviceID,
            &volAddress,
            DispatchQueue.main,
            block
        )

        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        _ = AudioObjectAddPropertyListenerBlock(
            defaultAudioDeviceID,
            &muteAddress,
            DispatchQueue.main
        ) { [weak self] _, _ in
            Task { @MainActor in
                self?.handleVolumeChanged()
            }
        }
    }

    // MARK: - Reading & Writing

    func readCurrentValues() {
        readVolume()
        readBrightness()
    }

    private func readVolume() {
        guard defaultAudioDeviceID != 0 else { return }

        var vol = Float32(0)
        var size = UInt32(MemoryLayout.size(ofValue: vol))
        var volAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(defaultAudioDeviceID, &volAddress, 0, nil, &size, &vol)
        if status == 0 {
            self.volume = max(0, min(1.0, vol))
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
        let res = getFn(CGMainDisplayID(), &current)
        if res == 0 {
            self.brightness = max(0, min(1.0, current))
        }
    }

    func setVolumeLevel(_ newVolume: Float) {
        let clamped = max(0, min(1.0, newVolume))
        self.volume = clamped

        guard defaultAudioDeviceID != 0 else { return }
        var vol = Float32(clamped)
        let size = UInt32(MemoryLayout.size(ofValue: vol))
        var volAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        _ = AudioObjectSetPropertyData(defaultAudioDeviceID, &volAddress, 0, nil, size, &vol)
        triggerHUD(type: .volume)
    }

    func setBrightnessLevel(_ newBrightness: Float) {
        let clamped = max(0, min(1.0, newBrightness))
        self.brightness = clamped

        guard let setFn = setBrightnessFn else { return }
        _ = setFn(CGMainDisplayID(), clamped)
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

    private func startBrightnessPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollBrightness()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.pollTimer = timer
    }

    private func pollBrightness() {
        guard let getFn = getBrightnessFn else { return }
        var current: Float = 0
        let res = getFn(CGMainDisplayID(), &current)
        guard res == 0 else { return }

        let clamped = max(0, min(1.0, current))
        if abs(clamped - self.brightness) > 0.015 {
            self.brightness = clamped
            if hasInitialized {
                triggerHUD(type: .brightness)
            }
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
