//
//  ClipboardManager.swift
//  NotchNotch
//
//  Tracks pasteboard changes, maintains history carousel items,
//  detects source application icons, and handles clipboard persistence.
//

import AppKit
import Combine
import Foundation
import OSLog

struct ClipboardItem: Identifiable, Codable, Equatable {
    let id: UUID
    let text: String
    let timestamp: Date
    var copyCount: Int
    var appBundleId: String?
    var appName: String?

    var ageString: String {
        let elapsed = max(0, -timestamp.timeIntervalSinceNow)
        if elapsed < 60 {
            return "now"
        } else if elapsed < 3600 {
            return "\(max(1, Int(elapsed / 60)))m"
        } else if elapsed < 86400 {
            return "\(max(1, Int(elapsed / 3600)))h"
        } else {
            return "\(max(1, Int(elapsed / 86400)))d"
        }
    }

    var appIcon: NSImage? {
        if let appBundleId,
           let appUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appBundleId) {
            return NSWorkspace.shared.icon(forFile: appUrl.path)
        }
        return nil
    }

    static func == (lhs: ClipboardItem, rhs: ClipboardItem) -> Bool {
        lhs.id == rhs.id && lhs.text == rhs.text && lhs.copyCount == rhs.copyCount
    }
}

@MainActor
final class ClipboardManager: ObservableObject {

    static let shared = ClipboardManager()

    @Published private(set) var items: [ClipboardItem] = []

    private var lastChangeCount: Int = -1
    private var pollTimer: Timer?
    private let persistenceURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("co.jianyuelab.NotchNotch", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        self.persistenceURL = appDir.appendingPathComponent("clipboard_history.json")

        loadPersisted()
        startMonitoring()
    }

    func startMonitoring() {
        lastChangeCount = NSPasteboard.general.changeCount

        // If history is empty on first boot, record current pasteboard
        if items.isEmpty {
            recordCurrentPasteboardIfAvailable()
        }

        // Poll pasteboard every 0.6 seconds in common runloop mode
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollPasteboard()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func pollPasteboard() {
        let currentCount = NSPasteboard.general.changeCount
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        guard let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        // Identify frontmost application that performed the copy
        let frontApp = NSWorkspace.shared.frontmostApplication
        let isSelf = frontApp?.bundleIdentifier == Bundle.main.bundleIdentifier
        let bundleId = isSelf ? nil : frontApp?.bundleIdentifier
        let appName = isSelf ? nil : frontApp?.localizedName

        record(text: text, bundleId: bundleId, appName: appName)
    }

    func record(text: String, bundleId: String?, appName: String?) {
        // If string already exists in history, bump copyCount and move to front
        if let existingIndex = items.firstIndex(where: { $0.text == text }) {
            var item = items.remove(at: existingIndex)
            item.copyCount += 1
            if let bundleId { item.appBundleId = bundleId }
            if let appName { item.appName = appName }
            items.insert(item, at: 0)
        } else {
            let newItem = ClipboardItem(
                id: UUID(),
                text: text,
                timestamp: Date(),
                copyCount: 1,
                appBundleId: bundleId,
                appName: appName
            )
            items.insert(newItem, at: 0)
            if items.count > 40 {
                items.removeLast()
            }
        }
        savePersisted()
    }

    func copyToPasteboard(item: ClipboardItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.text, forType: .string)
        lastChangeCount = NSPasteboard.general.changeCount
    }

    func clearAll() {
        items.removeAll()
        savePersisted()
    }


    private func recordCurrentPasteboardIfAvailable() {
        if let text = NSPasteboard.general.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            record(text: text, bundleId: "com.apple.Safari", appName: "Safari")
        }
    }

    // MARK: - Persistence

    private func loadPersisted() {
        guard FileManager.default.fileExists(atPath: persistenceURL.path),
              let data = try? Data(contentsOf: persistenceURL),
              let decoded = try? JSONDecoder().decode([ClipboardItem].self, from: data) else {
            return
        }
        items = decoded
    }

    private func savePersisted() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: persistenceURL, options: .atomic)
    }
}
