//
//  ShelfController.swift
//  NotchNotch
//
//  State and operations for the file drop shelf.
//  Handles adding, removing, clearing, opening, and persistent storage of staged items.
//

import AppKit
import Combine
import Foundation
import OSLog

@MainActor
final class ShelfController: ObservableObject {

    @Published private(set) var items: [ShelfItem] = []
    @Published var isTargeted: Bool = false

    private static let persistenceKey = "co.jianyuelab.NotchNotch.shelfPaths"

    init() {
        loadPersisted()
    }

    func addURLs(_ urls: [URL]) {
        let existingPaths = Set(items.map { $0.url.standardizedFileURL.path })
        var newItems = items

        for url in urls {
            let standard = url.standardizedFileURL
            guard !existingPaths.contains(standard.path),
                  FileManager.default.fileExists(atPath: standard.path) else {
                continue
            }
            newItems.insert(ShelfItem(url: standard), at: 0)
        }

        if newItems != items {
            items = newItems
            savePersisted()
            NSSound(named: "Purr")?.play()
            Log.lifecycle.notice("shelf: staged \(urls.count, privacy: .public) file(s), total \(self.items.count, privacy: .public)")
        }
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        savePersisted()
    }

    func clearAll() {
        items.removeAll()
        savePersisted()
        Log.lifecycle.notice("shelf: cleared all items")
    }

    func open(item: ShelfItem) {
        guard item.exists else { return }
        NSWorkspace.shared.open(item.url)
    }

    func revealInFinder(item: ShelfItem) {
        guard item.exists else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    // MARK: - Persistence

    private func loadPersisted() {
        guard let savedPaths = UserDefaults.standard.stringArray(forKey: Self.persistenceKey) else { return }
        let loaded = savedPaths.compactMap { path -> ShelfItem? in
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return ShelfItem(url: URL(fileURLWithPath: path))
        }
        items = loaded
    }

    private func savePersisted() {
        let paths = items.map { $0.url.path }
        UserDefaults.standard.set(paths, forKey: Self.persistenceKey)
    }
}
