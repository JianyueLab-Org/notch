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
    let formattedSize: String
    let icon: NSImage
    let addedAt: Date

    var exists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    init(id: UUID = UUID(), url: URL, addedAt: Date = Date()) {
        self.id = id
        self.url = url
        self.name = url.lastPathComponent
        self.addedAt = addedAt

        var size: Int64 = 0
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let fileLength = attrs[.size] as? Int64 {
            size = fileLength
        }
        self.fileSize = size
        self.formattedSize = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        self.icon = NSWorkspace.shared.icon(forFile: url.path)
    }

    static func == (lhs: ShelfItem, rhs: ShelfItem) -> Bool {
        lhs.id == rhs.id && lhs.url == rhs.url
    }
}
