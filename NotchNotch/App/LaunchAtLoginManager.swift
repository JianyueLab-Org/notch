//
//  LaunchAtLoginManager.swift
//  NotchNotch
//

import AppKit
import Foundation
import ServiceManagement
import Combine
import OSLog

@MainActor
final class LaunchAtLoginManager: ObservableObject {
    static let shared = LaunchAtLoginManager()

    @Published private(set) var isEnabled: Bool = false
    @Published private(set) var requiresApproval: Bool = false

    private var activationCancellable: AnyCancellable?

    private init() {
        refreshStatus()
        activationCancellable = NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.refreshStatus()
                }
            }
    }

    func refreshStatus() {
        let status = SMAppService.mainApp.status
        isEnabled = (status == .enabled)
        requiresApproval = (status == .requiresApproval)
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                let status = SMAppService.mainApp.status
                if status == .enabled || status == .requiresApproval {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            Log.lifecycle.error("LaunchAtLoginManager: failed to setEnabled(\(enabled)): \(error.localizedDescription)")
        }
        refreshStatus()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
