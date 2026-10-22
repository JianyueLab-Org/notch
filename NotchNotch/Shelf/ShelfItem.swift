//
//  ShelfItem.swift
//  NotchNotch
//
//  Represents a single file or folder currently staged in the Drop Shelf.
//

import AppKit
import Foundation

struct ShelfItem: Identifiable, Equatable {
    let id: UUID
    let url: URL
    let name: String
    let fileSize: Int64
    /// nil for packages: their directory entry size is meaningless and a child count
    /// ("1 item" for every .app) is no better.
    let formattedSize: String?
    let icon: NSImage
    let addedAt: Date
    /// Persisted instead of the path so a staged file survives being moved or renamed.
    let bookmark: Data?

    var exists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    init(id: UUID = UUID(), url: URL, addedAt: Date = Date(), bookmark: Data? = nil) {
        self.id = id
        self.url = url
        self.name = url.lastPathComponent
        self.addedAt = addedAt
        self.bookmark = bookmark ?? (try? url.bookmarkData())

        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        var size: Int64 = 0
        if values?.isDirectory == true {
            // A directory's own `.size` is its entry in the parent ("96 bytes"), not
            // its contents; the child count is the cheap, honest alternative.
            if values?.isPackage == true {
                self.formattedSize = nil
            } else {
                let children = (try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles))?.count ?? 0
                self.formattedSize = L10n.tr(.shelfFolderItemCount, children)
            }
        } else {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let fileLength = attrs[.size] as? Int64 {
                size = fileLength
            }
            self.formattedSize = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        }
        self.fileSize = size
        self.icon = NSWorkspace.shared.icon(forFile: url.path)
    }

    static func == (lhs: ShelfItem, rhs: ShelfItem) -> Bool {
        lhs.id == rhs.id && lhs.url == rhs.url
    }
}
