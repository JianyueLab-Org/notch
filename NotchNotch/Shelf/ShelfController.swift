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

    private static let persistenceKey = "co.jianyuelab.NotchNotch.shelfBookmarks"
    /// Pre-bookmark storage; read once to migrate, then removed.
    private static let legacyPathsKey = "co.jianyuelab.NotchNotch.shelfPaths"

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
        // Newest first, so the cap drops the oldest staged items.
        if newItems.count > NotchConfiguration.shelfMaxItems {
            newItems = Array(newItems.prefix(NotchConfiguration.shelfMaxItems))
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
        let defaults = UserDefaults.standard
        if let bookmarks = defaults.array(forKey: Self.persistenceKey) as? [Data] {
            var needsSave = false
            items = bookmarks.compactMap { data -> ShelfItem? in
                var isStale = false
                guard let url = try? URL(
                    resolvingBookmarkData: data,
                    options: [.withoutUI, .withoutMounting],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                ), FileManager.default.fileExists(atPath: url.path) else {
                    needsSave = true
                    return nil
                }
                // A stale bookmark still resolved; re-mint it so the next launch does too.
                if isStale { needsSave = true }
                return ShelfItem(url: url, bookmark: isStale ? nil : data)
            }
            if needsSave { savePersisted() }
        } else if let savedPaths = defaults.stringArray(forKey: Self.legacyPathsKey) {
            items = savedPaths.compactMap { path -> ShelfItem? in
                guard FileManager.default.fileExists(atPath: path) else { return nil }
                return ShelfItem(url: URL(fileURLWithPath: path))
            }
            savePersisted()
            defaults.removeObject(forKey: Self.legacyPathsKey)
        }
    }

    private func savePersisted() {
        let bookmarks = items.compactMap(\.bookmark)
        UserDefaults.standard.set(bookmarks, forKey: Self.persistenceKey)
    }
}
