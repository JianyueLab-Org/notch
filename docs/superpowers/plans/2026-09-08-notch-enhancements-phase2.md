# NotchNotch Phase 2.1 & 2.2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enhance NotchNotch with Apple Music native scripting, a macOS Big Sur+ native app icon set, and a productivity Drop Shelf for staging files with drag-out capability and automatic context switching.

**Architecture:** Extend the media subsystem with `MusicScriptingSource` conforming to `NowPlayingSource`; create a dedicated `ShelfController` managing staged file URLs with deduplication and persistence; update `NotchOverlayWindow` and `NotchHoverMonitor` to detect and route drag sessions; and embed a segmented pill header in `NotchPanelView` to switch between `NowPlayingView` and the new `DropShelfView`.

**Tech Stack:** Swift 6 / SwiftUI (macOS 13.0+ deployment target), AppKit (`NSPanel`, `NSWorkspace`, `NSItemProvider`, `NSRunningApplication`, `NSAppleScript`), Python 3 (Pillow) for asset rendering.

**Spec:** [`docs/superpowers/specs/2026-09-08-notch-enhancements-phase2-design.md`](file:///Users/jhl/Documents/Dev/NotchNotch/docs/superpowers/specs/2026-09-08-notch-enhancements-phase2-design.md)

## Global Constraints

- Platform: macOS 13.0+ (`MACOSX_DEPLOYMENT_TARGET = 13.0`).
- Strict Swift concurrency rules: `@MainActor` isolation for UI and controllers, `nonisolated` where appropriate.
- Zero-crash & graceful degradation: Any missing symbols or denied permissions must degrade cleanly without crashing or freezing the main thread.
- Xcode File System Synchronized Groups: `NotchNotch/` is a synchronized group (`PBXFileSystemSynchronizedRootGroup`), so files created in `NotchNotch/` are automatically included in compilation.
- Verification: Every task must build cleanly via `xcodebuild -scheme NotchNotch -destination 'platform=macOS' build` with zero warnings/errors.

---

### Task 1: Generate macOS Native AppIcon Suite

**Files:**
- Create: `scripts/generate_app_icon.py`
- Modify: `NotchNotch/Assets.xcassets/AppIcon.appiconset/Contents.json`
- Produce: All PNG icon assets in `NotchNotch/Assets.xcassets/AppIcon.appiconset/`

**Interfaces:**
- Consumes: None
- Produces: Standard macOS AppIcon asset catalog containing 16x16, 32x32, 64x64, 128x128, 256x256, 512x512, 1024x1024 icons.

- [ ] **Step 1: Write python icon generator script**

Create `scripts/generate_app_icon.py`:

```python
#!/usr/bin/env python3
import os
import json
import math
from PIL import Image, ImageDraw, ImageFilter

def render_base_icon(size=1024):
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    
    # macOS standard icon canvas inset: ~824px squircle inside 1024px canvas
    margin = int(size * 0.1)
    box = [margin, margin, size - margin, size - margin]
    corner_radius = int(size * 0.2)
    
    # Outer dark body (Obsidian / Space Gray)
    draw.rounded_rectangle(box, radius=corner_radius, fill=(24, 24, 28, 255))
    
    # Subtle inner border stroke
    stroke_box = [margin + 1, margin + 1, size - margin - 1, size - margin - 1]
    draw.rounded_rectangle(stroke_box, radius=corner_radius - 1, outline=(255, 255, 255, 30), width=4)
    
    # Top rim specular highlight
    highlight_box = [margin + 6, margin + 6, size - margin - 6, margin + int(size * 0.15)]
    draw.rounded_rectangle(highlight_box, radius=int(corner_radius * 0.6), fill=(255, 255, 255, 12))

    # Glow layer underneath notch
    glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    glow_draw = ImageDraw.Draw(glow)
    
    notch_w = int(size * 0.38)
    notch_h = int(size * 0.08)
    notch_top = margin + 10
    notch_left = (size - notch_w) // 2
    
    # Neon gradient glow under notch
    glow_box = [notch_left - 30, notch_top + notch_h - 10, notch_left + notch_w + 30, notch_top + notch_h + 80]
    glow_draw.ellipse(glow_box, fill=(56, 189, 248, 140)) # cyan
    glow_box2 = [notch_left + 40, notch_top + notch_h, notch_left + notch_w - 40, notch_top + notch_h + 60]
    glow_draw.ellipse(glow_box2, fill=(168, 85, 247, 160)) # purple
    
    glow = glow.filter(ImageFilter.GaussianBlur(radius=28))
    image = Image.alpha_composite(image, glow)
    draw = ImageDraw.Draw(image)
    
    # Notch silhouette: solid black pill attached to top border
    notch_r = int(notch_h * 0.45)
    notch_box = [notch_left, notch_top, notch_left + notch_w, notch_top + notch_h]
    draw.rounded_rectangle(notch_box, radius=notch_r, fill=(10, 10, 12, 255))
    draw.rounded_rectangle(notch_box, radius=notch_r, outline=(255, 255, 255, 45), width=2)
    
    # Camera dot & sensor
    cam_x = size // 2
    cam_y = notch_top + notch_h // 2
    draw.ellipse([cam_x - 5, cam_y - 5, cam_x + 5, cam_y + 5], fill=(20, 24, 38, 255), outline=(56, 189, 248, 80), width=1)
    
    # Music note wave symbol inside the body
    center_y = int(size * 0.58)
    wave_points = []
    for i in range(12):
        bx = int(size * 0.3) + i * int(size * 0.035)
        h = int(math.sin(i * 0.7) * 45) + 60
        draw.rounded_rectangle([bx, center_y - h//2, bx + 12, center_y + h//2], radius=6, fill=(240, 240, 250, 220))
        
    return image

def main():
    target_dir = os.path.abspath("NotchNotch/Assets.xcassets/AppIcon.appiconset")
    os.makedirs(target_dir, exist_ok=True)
    
    base = render_base_icon(1024)
    
    specs = [
        (16, 1, "icon_16x16.png"),
        (16, 2, "icon_16x16@2x.png"),
        (32, 1, "icon_32x32.png"),
        (32, 2, "icon_32x32@2x.png"),
        (128, 1, "icon_128x128.png"),
        (128, 2, "icon_128x128@2x.png"),
        (256, 1, "icon_256x256.png"),
        (256, 2, "icon_256x256@2x.png"),
        (512, 1, "icon_512x512.png"),
        (512, 2, "icon_512x512@2x.png"),
    ]
    
    contents_images = []
    for size_pt, scale, filename in specs:
        pixel_size = size_pt * scale
        resized = base.resize((pixel_size, pixel_size), Image.Resampling.LANCZOS)
        resized.save(os.path.join(target_dir, filename), "PNG")
        contents_images.append({
            "size": f"{size_pt}x{size_pt}",
            "idiom": "mac",
            "filename": filename,
            "scale": f"{scale}x"
        })
        
    contents = {
        "images": contents_images,
        "info": {"author": "xcode", "version": 1}
    }
    with open(os.path.join(target_dir, "Contents.json"), "w") as f:
        json.dump(contents, f, indent=2)
    print("Successfully generated all AppIcon assets.")

if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Run icon generator**

Run: `python3 scripts/generate_app_icon.py`
Expected: "Successfully generated all AppIcon assets." and 10 PNG files in `NotchNotch/Assets.xcassets/AppIcon.appiconset/`.

- [ ] **Step 3: Commit**

```bash
git add scripts/generate_app_icon.py NotchNotch/Assets.xcassets/AppIcon.appiconset/
git commit -m "feat: generate native macOS AppIcon asset suite"
```

---

### Task 2: Implement Apple Music Scripting Source (`MusicScriptingSource.swift`)

**Files:**
- Create: `NotchNotch/Media/MusicScriptingSource.swift`
- Modify: `NotchNotch/Notch/NotchWindowController.swift:30-34`

**Interfaces:**
- Consumes: `NowPlayingSource` protocol, `NowPlaying` model, `Log.media`.
- Produces: `MusicScriptingSource` class wired into `CompositeNowPlayingSource`.

- [ ] **Step 1: Write `MusicScriptingSource.swift`**

Create `NotchNotch/Media/MusicScriptingSource.swift`:

```swift
//
//  MusicScriptingSource.swift
//  NotchNotch
//
//  Reads and controls Apple Music over AppleScript.
//  Extracts title, artist, album, duration, live position, player state,
//  and local raw artwork bytes.
//

import AppKit
import CoreServices
import OSLog

@MainActor
final class MusicScriptingSource: NowPlayingSource {

    static let bundleIdentifier = "com.apple.Music"

    var onChange: ((NowPlaying?) -> Void)?

    private(set) var authorization: NowPlayingAuthorization = .notRequired

    var isAvailable: Bool { Self.isMusicRunning && !authorization.isBlocked }

    private var pollTask: Task<Void, Never>?
    private var script: NSAppleScript?
    private var artworkScript: NSAppleScript?
    private var artworkCache: (trackId: String, image: NSImage)?
    private var artworkTask: Task<Void, Never>?
    private var lastLoggedTitle: String??

    private static var isMusicRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    // MARK: - Lifecycle

    func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.tick()
                try? await Task.sleep(for: NotchConfiguration.spotifyPollInterval)
            }
        }
        Log.media.notice("media: Music scripting source started (running=\(Self.isMusicRunning, privacy: .public))")
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        artworkTask?.cancel()
        artworkTask = nil
        Log.media.notice("media: Music scripting source stopped")
    }

    func send(_ command: MediaCommand) {
        guard Self.isMusicRunning else { return }
        let verb = switch command {
        case .togglePlayPause: "playpause"
        case .nextTrack: "next track"
        case .previousTrack: "previous track"
        }
        _ = run("tell application id \"\(Self.bundleIdentifier)\" to \(verb)")
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            self?.tick()
        }
    }

    func requestAuthorization() {
        guard Self.isMusicRunning else {
            Log.media.notice("media: cannot request Music automation — Music is not running")
            return
        }
        _ = permissionStatus(askUserIfNeeded: true)
        tick()
    }

    // MARK: - Polling

    private func tick() {
        guard Self.isMusicRunning else {
            report(nil)
            return
        }

        switch permissionStatus(askUserIfNeeded: false) {
        case noErr:
            if authorization != .granted {
                authorization = .granted
                Log.media.notice("media: Music automation permitted")
            }
        case OSStatus(errAEEventWouldRequireUserConsent):
            setNeedsPermission("NotchNotch needs permission to control Apple Music.")
            return
        case OSStatus(errAEEventNotPermitted):
            setNeedsPermission("Allow NotchNotch to control Music in System Settings › Privacy & Security › Automation.")
            return
        case OSStatus(procNotFound):
            report(nil)
            return
        default:
            break
        }

        guard let descriptor = run(Self.readScript) else { return }
        report(makeTrack(from: descriptor))
    }

    private func permissionStatus(askUserIfNeeded: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: Self.bundleIdentifier)
        return withUnsafePointer(to: target.aeDesc!.pointee) { pointer in
            AEDeterminePermissionToAutomateTarget(pointer, typeWildCard, typeWildCard, askUserIfNeeded)
        }
    }

    private func setNeedsPermission(_ message: String) {
        let next = NowPlayingAuthorization.needsPermission(message)
        if authorization != next {
            authorization = next
            Log.media.notice("media: Music automation not granted — \(message, privacy: .public)")
        }
        report(nil)
    }

    private static let readScript = """
    tell application id "\(bundleIdentifier)"
        set st to "stopped"
        if player state is playing then
            set st to "playing"
        else if player state is paused then
            set st to "paused"
        end if
        set pos to 0
        try
            set pos to player position
        end try
        try
            set t to current track
            set trName to name of t
            set trArtist to artist of t
            set trAlbum to album of t
            set trDur to duration of t
            set trId to (id of t) as text
            return {trName, trArtist, trAlbum, trDur as text, pos as text, st, trId}
        on error
            return {"", "", "", "0", "0", st, ""}
        end try
    end tell
    """

    private static let rawArtworkScript = """
    tell application id "\(bundleIdentifier)"
        try
            set t to current track
            if (count of artworks of t) > 0 then
                return raw data of artwork 1 of t
            end if
        end try
        return ""
    end tell
    """

    private func run(_ source: String) -> NSAppleEventDescriptor? {
        let compiled: NSAppleScript?
        if source == Self.readScript {
            if script == nil { script = NSAppleScript(source: source) }
            compiled = script
        } else if source == Self.rawArtworkScript {
            if artworkScript == nil { artworkScript = NSAppleScript(source: source) }
            compiled = artworkScript
        } else {
            compiled = NSAppleScript(source: source)
        }
        guard let compiled else { return nil }

        var error: NSDictionary?
        let result = compiled.executeAndReturnError(&error)
        if let error {
            handle(error)
            return nil
        }
        if authorization != .granted {
            authorization = .granted
        }
        return result
    }

    private func handle(_ error: NSDictionary) {
        let code = error[NSAppleScript.errorNumber] as? Int ?? 0
        switch code {
        case -1743:
            if !authorization.isBlocked {
                authorization = .needsPermission(
                    "Allow NotchNotch to control Music in System Settings › Privacy & Security › Automation.")
                Log.media.error("media: Music automation denied (-1743)")
            }
        case -600, -609:
            report(nil)
        default:
            Log.media.error("media: Music AppleScript error \(code, privacy: .public)")
        }
    }

    // MARK: - Parsing

    private func makeTrack(from descriptor: NSAppleEventDescriptor) -> NowPlaying? {
        func field(_ index: Int) -> String {
            descriptor.atIndex(index)?.stringValue ?? ""
        }
        let title = field(1)
        let artist = field(2)
        let album = field(3)
        let duration = Double(field(4)) ?? 0
        let position = Double(field(5)) ?? 0
        let state = field(6)
        let trackId = field(7)

        guard !title.isEmpty || !artist.isEmpty else { return nil }

        let isPlaying = state == "playing"

        if !trackId.isEmpty {
            fetchArtworkIfNeeded(trackId: trackId)
        }

        return NowPlaying(
            title: title,
            artist: artist,
            album: album,
            isPlaying: isPlaying,
            duration: max(duration, 0),
            reportedElapsed: position,
            reportedAt: Date(),
            playbackRate: isPlaying ? 1 : 0,
            artworkIdentifier: trackId.isEmpty ? nil : trackId,
            artwork: artworkCache?.trackId == trackId ? artworkCache?.image : nil,
            clientBundleIdentifier: Self.bundleIdentifier
        )
    }

    private func fetchArtworkIfNeeded(trackId: String) {
        guard artworkCache?.trackId != trackId else { return }
        artworkTask?.cancel()
        artworkTask = Task { [weak self] in
            guard let self else { return }
            guard let desc = self.run(Self.rawArtworkScript),
                  let data = desc.data,
                  !data.isEmpty,
                  let image = NSImage(data: data) else {
                return
            }
            guard !Task.isCancelled else { return }
            self.artworkCache = (trackId, image)
            self.tick()
        }
    }

    private func report(_ track: NowPlaying?) {
        if lastLoggedTitle != .some(track?.title) {
            lastLoggedTitle = .some(track?.title)
            Log.media.notice("media: Music \(track?.title ?? "(nothing)", privacy: .public)")
        }
        onChange?(track)
    }

    deinit {
        pollTask?.cancel()
        artworkTask?.cancel()
    }
}
```

- [ ] **Step 2: Update `NotchWindowController.swift` to add `MusicScriptingSource`**

Modify `NotchNotch/Notch/NotchWindowController.swift` lines 30-34:
```swift
    private let nowPlaying = NowPlayingController(source: CompositeNowPlayingSource(children: [
        SpotifyScriptingSource(),
        MusicScriptingSource(),
        AccessibilityNowPlayingSource(),
    ]))
```

- [ ] **Step 3: Build verification**

Run: `xcodebuild -scheme NotchNotch -destination 'platform=macOS' build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add NotchNotch/Media/MusicScriptingSource.swift NotchNotch/Notch/NotchWindowController.swift
git commit -m "feat: add Apple Music native scripting source"
```

---

### Task 3: Implement Drop Shelf Data Model & Controller (`ShelfItem.swift` & `ShelfController.swift`)

**Files:**
- Create: `NotchNotch/Shelf/ShelfItem.swift`
- Create: `NotchNotch/Shelf/ShelfController.swift`

**Interfaces:**
- Consumes: `NSWorkspace.shared.icon(forFile:)`, `UserDefaults`.
- Produces: `ShelfItem` model and `@MainActor class ShelfController: ObservableObject`.

- [ ] **Step 1: Write `ShelfItem.swift`**

Create `NotchNotch/Shelf/ShelfItem.swift`:

```swift
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
```

- [ ] **Step 2: Write `ShelfController.swift`**

Create `NotchNotch/Shelf/ShelfController.swift`:

```swift
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
```

- [ ] **Step 3: Build verification**

Run: `xcodebuild -scheme NotchNotch -destination 'platform=macOS' build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add NotchNotch/Shelf/ShelfItem.swift NotchNotch/Shelf/ShelfController.swift
git commit -m "feat: implement ShelfItem model and ShelfController store"
```

---

### Task 4: Implement Drop Shelf View (`DropShelfView.swift`)

**Files:**
- Create: `NotchNotch/Views/DropShelfView.swift`

**Interfaces:**
- Consumes: `ShelfController`, `ShelfItem`.
- Produces: `DropShelfView` SwiftUI view supporting `.onDrop` and item `.onDrag`.

- [ ] **Step 1: Write `DropShelfView.swift`**

Create `NotchNotch/Views/DropShelfView.swift`:

```swift
//
//  DropShelfView.swift
//  NotchNotch
//
//  The file staging shelf view.
//  Renders empty state, drop target highlight, file card carousel, and drag-out support.
//

import SwiftUI
import UniformTypeIdentifiers

struct DropShelfView: View {

    @ObservedObject var shelf: ShelfController

    var body: some View {
        VStack(spacing: 8) {
            if shelf.items.isEmpty {
                emptyDropTarget
            } else {
                itemsContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $shelf.isTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    // MARK: - Subviews

    private var emptyDropTarget: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    shelf.isTargeted ? Color.accentColor : Color.white.opacity(0.18),
                    style: StrokeStyle(lineWidth: shelf.isTargeted ? 2 : 1.5, dash: shelf.isTargeted ? [] : [6, 4])
                )
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(shelf.isTargeted ? Color.accentColor.opacity(0.12) : Color.white.opacity(0.04))
                )

            VStack(spacing: 6) {
                Image(systemName: shelf.isTargeted ? "arrow.down.doc.fill" : "tray.and.arrow.down")
                    .font(.system(size: 24))
                    .foregroundStyle(shelf.isTargeted ? Color.accentColor : .white.opacity(0.4))
                Text(shelf.isTargeted ? "Release to stage files" : "Drop files here to hold")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(shelf.isTargeted ? 0.95 : 0.6))
                Text("Drag out anytime to transfer across apps")
                    .font(.system(size: 10, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private var itemsContent: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(shelf.items) { item in
                        itemCard(item)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }

            HStack {
                Text("\(shelf.items.count) item\(shelf.items.count == 1 ? "" : "s") staged")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                Button("Clear All") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        shelf.clearAll()
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(.white.opacity(0.12)))
            }
            .padding(.horizontal, 4)
        }
    }

    private func itemCard(_ item: ShelfItem) -> some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: item.icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 40, height: 40)
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 2)

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        shelf.remove(id: item.id)
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.75), .black.opacity(0.6))
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
            }

            Text(item.name)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 72)

            Text(item.formattedSize)
                .font(.system(size: 8, weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
        .contentShape(Rectangle())
        .onDrag {
            NSItemProvider(contentsOf: item.url) ?? NSItemProvider()
        }
        .onTapGesture(count: 2) {
            shelf.open(item: item)
        }
        .contextMenu {
            Button("Open") { shelf.open(item: item) }
            Button("Reveal in Finder") { shelf.revealInFinder(item: item) }
            Divider()
            Button("Remove") { shelf.remove(id: item.id) }
        }
    }

    // MARK: - Drop Handling

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var foundURLs: [URL] = []
        let group = DispatchGroup()

        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    foundURLs.append(url)
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            if !foundURLs.isEmpty {
                self.shelf.addURLs(foundURLs)
            }
        }

        return true
    }
}
```

- [ ] **Step 2: Build verification**

Run: `xcodebuild -scheme NotchNotch -destination 'platform=macOS' build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add NotchNotch/Views/DropShelfView.swift
git commit -m "feat: implement DropShelfView with drop zone, cards and drag-out"
```

---

### Task 5: Integrate Tabbed Header, Auto-Switching, and Drag Coordination

**Files:**
- Modify: `NotchNotch/Views/NotchPanelView.swift`
- Modify: `NotchNotch/Notch/NotchOverlayWindow.swift`
- Modify: `NotchNotch/Notch/NotchWindowController.swift`
- Modify: `NotchNotch/Notch/NotchHoverMonitor.swift`

**Interfaces:**
- Consumes: `NowPlayingController`, `ShelfController`, `NotchStateMachine`.
- Produces: Integrated Notch panel with active tab segmented pill, drag auto-switching to Shelf, and dragging destination registration.

- [ ] **Step 1: Update `NotchOverlayWindow.swift` to register for dragged types**

In `NotchNotch/Notch/NotchOverlayWindow.swift`, add in `init`:
```swift
registerForDraggedTypes([.fileURL])
```

- [ ] **Step 2: Update `NotchPanelView.swift` to add segmented header and shelf tab**

Replace `NotchNotch/Views/NotchPanelView.swift` with:
```swift
//
//  NotchPanelView.swift
//  NotchNotch
//
//  The visual shell with segmented navigation between Now Playing and Drop Shelf.
//

import SwiftUI

enum NotchActiveTab: String, CaseIterable, Identifiable {
    case nowPlaying = "Now Playing"
    case shelf = "Drop Shelf"
    var id: String { rawValue }
}

struct NotchPanelView: View {

    @ObservedObject var machine: NotchStateMachine
    @ObservedObject var media: NowPlayingController
    @ObservedObject var shelf: ShelfController
    @Binding var activeTab: NotchActiveTab

    private var isOpen: Bool { machine.state.isVisiblyExpanded }

    private var bodySize: CGSize {
        isOpen ? machine.layout.expandedSize : machine.layout.collapsedSize
    }

    var body: some View {
        VStack(spacing: 0) {
            panel
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var panel: some View {
        NotchShape(topRadius: isOpen ? NotchConfiguration.expandedTopCornerRadius
                                     : NotchConfiguration.collapsedTopCornerRadius,
                   bottomRadius: isOpen ? NotchConfiguration.expandedBottomCornerRadius
                                        : NotchConfiguration.collapsedBottomCornerRadius)
            .fill(Color.black)
            .overlay(alignment: .top) {
                if machine.state.isOnScreen { expandedContent }
            }
            .frame(width: bodySize.width, height: bodySize.height)
            .shadow(color: .black.opacity(isOpen ? 0.45 : 0), radius: 14, y: 6)
    }

    @ViewBuilder
    private var expandedContent: some View {
        VStack(spacing: 10) {
            tabHeader

            Group {
                switch activeTab {
                case .nowPlaying:
                    mediaContent
                case .shelf:
                    DropShelfView(shelf: shelf)
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
        }
        .padding(.horizontal, 18)
        .padding(.top, machine.layout.geometry.notchRect.height + 4)
        .padding(.bottom, 14)
        .frame(width: machine.layout.expandedSize.width,
               height: machine.layout.expandedSize.height)
        .foregroundStyle(.white)
        .opacity(isOpen ? 1 : 0)
        .allowsHitTesting(isOpen)
        .clipped()
    }

    private var tabHeader: some View {
        HStack(spacing: 4) {
            tabButton(tab: .nowPlaying, systemImage: "music.note", title: "Playing", badge: nil)
            tabButton(tab: .shelf, systemImage: "tray.full", title: "Shelf", badge: shelf.items.isEmpty ? nil : "\(shelf.items.count)")
        }
        .padding(3)
        .background(Capsule().fill(Color.white.opacity(0.10)))
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func tabButton(tab: NotchActiveTab, systemImage: String, title: String, badge: String?) -> some View {
        let isSelected = activeTab == tab
        return Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                activeTab = tab
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                if let badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(isSelected ? Color.white.opacity(0.25) : Color.accentColor))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(isSelected ? Color.white.opacity(0.18) : Color.clear)
            )
            .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.55))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var mediaContent: some View {
        if let track = media.nowPlaying, track.hasTrack {
            NowPlayingView(track: track) { media.send($0) }
        } else {
            emptyMediaState
        }
    }

    @ViewBuilder
    private var emptyMediaState: some View {
        VStack(spacing: 8) {
            if case .needsPermission(let reason) = media.authorization {
                Image(systemName: "lock.shield")
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.35))
                Text(reason)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Grant Access…") { media.requestAuthorization() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Capsule().fill(.white.opacity(0.16)))
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.3))
                Text("Nothing playing")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

- [ ] **Step 3: Update `NotchWindowController.swift` to pass `ShelfController` and wire drag detection**

In `NotchNotch/Notch/NotchWindowController.swift`:
1. Add property `private let shelf = ShelfController()`
2. Add `@Published var activeTab: NotchActiveTab = .nowPlaying` (or state)
3. In `buildWindowIfNeeded()`, initialize `NotchPanelView`:
   ```swift
   let panelView = NotchPanelView(
       machine: stateMachine,
       media: nowPlaying,
       shelf: shelf,
       activeTab: Binding(get: { [weak self] in self?.activeTab ?? .nowPlaying },
                          set: { [weak self] in self?.activeTab = $0 })
   )
   let hosting = NSHostingView(rootView: panelView)
   ```
4. In `NotchHoverMonitor` callback:
   When `NSEvent.currentEvent` is a drag event (`.leftMouseDragged`, `.rightMouseDragged`), automatically switch `activeTab = .shelf` when entering the notch:
   ```swift
   let monitor = NotchHoverMonitor { [weak self] location, isDragging in
       guard let self else { return }
       self.lastPointer = location
       if isDragging && self.stateMachine.state == .collapsed {
           self.activeTab = .shelf
       }
       self.stateMachine.pointerMoved(to: location)
       self.updateInteractivity(for: self.stateMachine.state)
   }
   ```

- [ ] **Step 4: Update `NotchHoverMonitor.swift` to deliver `isDragging`**

Update `NotchHoverMonitor.swift` callback signature to `(CGPoint, Bool) -> Void`:
Check if event type is one of the drag types (`[.leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(event.type)`).

- [ ] **Step 5: Build verification**

Run: `xcodebuild -scheme NotchNotch -destination 'platform=macOS' build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add NotchNotch/Notch/NotchOverlayWindow.swift NotchNotch/Notch/NotchHoverMonitor.swift NotchNotch/Notch/NotchWindowController.swift NotchNotch/Views/NotchPanelView.swift
git commit -m "feat: wire tabbed header, drag detection, and Drop Shelf integration"
```

---

### Task 6: End-to-End Build, Integration Testing, and Verification

**Files:**
- Test all components end-to-end.
- Check clean build on macOS target.

- [ ] **Step 1: Clean build**

Run: `xcodebuild -scheme NotchNotch -destination 'platform=macOS' clean build`
Expected: `** BUILD SUCCEEDED **` with zero warnings and zero errors.

- [ ] **Step 2: Inspect app bundle packaging**

Verify the built `.app` bundle:
Check that `NotchNotch.app/Contents/Resources/AppIcon.icns` or asset catalog `Assets.car` is present, `LSUIElement` is intact, and all binary architectures (arm64/x86_64) are compiled.

- [ ] **Step 3: Final commit**

```bash
git status
git commit -m "chore: verify end-to-end build and complete Phase 2.1 & 2.2 integration"
```
