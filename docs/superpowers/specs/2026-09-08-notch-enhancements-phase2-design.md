# NotchNotch Phase 2.1 & 2.2 Design Spec

- **Author**: Antigravity & Jianyue Hugo Liang
- **Date**: 2026-09-08
- **Status**: Approved by User
- **Target**: macOS 13.0+

---

## 1. Overview & Goals

NotchNotch currently provides a native macOS notch overlay that drops down on hover, displaying playback information from Spotify or general audio via Accessibility fallback.

This specification covers two distinct enhancement phases:
1. **Phase 2.1 (Core Experience & Ecosystem Polish)**:
   - **Apple Music native integration**: Direct AppleScript scripting source (`MusicScriptingSource`) providing full metadata, cover art extraction, real-time playback position, and transport controls for macOS's built-in Music.app (`com.apple.Music`).
   - **macOS Native App Icon**: High-precision icon suite generated for all required resolutions (`16x16` up to `1024x1024`) adhering to Apple Human Interface Guidelines for macOS Big Sur+.
2. **Phase 2.2 (Productivity Enhancement: Drop Shelf)**:
   - **File Drop Shelf**: A temporary staging shelf embedded into the notch. Dragging any files/folders to the notch opens the panel and stages them.
   - **Bidirectional Drag & Drop**: Files can be dropped into the shelf to hold, and dragged back out to any external application (Finder, browsers, communication tools) for easy cross-workspace file transit.
   - **Smart Context Switching**: Segmented pill navigation at the top of the panel, with automatic switching to the Drop Shelf whenever an active file drag is detected entering the notch.

---

## 2. Architecture & Subsystems

```
┌─────────────────────────────────────────────────────────────┐
│                    NotchWindowController                    │
│   (Coordinates Window, StateMachine, HoverMonitor, Stores)   │
└──────────────┬───────────────────────────────┬──────────────┘
               │                               │
       ┌───────▼────────┐             ┌────────▼────────┐
       │ Media Subsystem│             │ Shelf Subsystem │
       └───────┬────────┘             └────────┬────────┘
               │                               │
    ┌──────────┴──────────┐                    │
    │CompositeNowPlaying  │             ┌──────▼────────┐
    │       Source        │             │ShelfController│
    └────┬───────────┬────┘             └──────┬────────┘
         │           │                         │
  ┌──────▼──────┐ ┌──▼──────────┐              │
  │SpotifySource│ │MusicSource  │              │
  └─────────────┘ └─────────────┘              │
                                               │
┌──────────────────────────────────────────────▼──────────────┐
│                    NotchPanelView                           │
│   ┌─────────────────────────────────────────────────────┐   │
│   │ Top Segmented Header [ ♫ Now Playing | 📁 Shelf (N)]│   │
│   └─────────────────────────────────────────────────────┘   │
│   ┌─────────────────────────┬───────────────────────────┐   │
│   │     NowPlayingView      │       DropShelfView       │   │
│   └─────────────────────────┴───────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

---

## 3. Detailed Component Specifications

### 3.1 Apple Music Scripting Source (`MusicScriptingSource.swift`)

- **Protocol Conformance**: Conforms to `NowPlayingSource`.
- **Target Bundle**: `com.apple.Music`.
- **Process Guard**: Checks `NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")` before dispatching any events. If Music is not running, reports `nil` and performs zero background launches.
- **Permission Check**: Uses `AEDeterminePermissionToAutomateTarget` with `askUserIfNeeded: false` during periodic ticks to prevent main thread blocking, and `askUserIfNeeded: true` only upon explicit user action.
- **Metadata Scripting**:
  Queries `current track` for:
  - `name`, `artist`, `album`, `duration` (in seconds), `player position` (in seconds), `player state` (playing/paused/stopped), `id` (persistent track ID).
- **Artwork Extraction**:
  - Apple Music stores artwork in the local library. The source executes:
    ```applescript
    tell application id "com.apple.Music"
        try
            set t to current track
            if (count of artworks of t) > 0 then
                return raw data of artwork 1 of t
            end if
        end try
        return ""
    end tell
    ```
  - The resulting descriptor bytes are decoded via `NSImage(data:)` and cached against `trackId`.
- **Transport Commands**: Sends `playpause`, `next track`, `previous track` via AppleScript.
- **Priority Aggregation**:
  In `NotchWindowController.swift`, `CompositeNowPlayingSource` will order sources as:
  1. `SpotifyScriptingSource`
  2. `MusicScriptingSource`
  3. `AccessibilityNowPlayingSource`

---

### 3.2 macOS Native App Icon Suite

- **Design**:
  - Rounded squircle conforming to macOS 13+ icon specs.
  - Deep space-gray / obsidian frosted texture with top specular edge highlight.
  - Precise physical notch silhouette inset at top center, with subtle neon cyan/purple glow radiating underneath.
- **Artifacts**:
  Generated via Python script into `NotchNotch/Assets.xcassets/AppIcon.appiconset/`:
  - `icon_16x16.png`, `icon_16x16@2x.png`
  - `icon_32x32.png`, `icon_32x32@2x.png`
  - `icon_128x128.png`, `icon_128x128@2x.png`
  - `icon_256x256.png`, `icon_256x256@2x.png`
  - `icon_512x512.png`, `icon_512x512@2x.png`
  - Fully populated `Contents.json`.

---

### 3.3 Drop Shelf Subsystem (`ShelfItem.swift` & `ShelfController.swift`)

#### Data Model: `ShelfItem`
```swift
struct ShelfItem: Identifiable, Equatable {
    let id: UUID
    let url: URL
    let name: String
    let fileSize: Int64
    let formattedSize: String
    let icon: NSImage
    let addedAt: Date
    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }
}
```

#### Controller: `ShelfController` (`ObservableObject`, `@MainActor`)
- **Published Properties**:
  - `@Published private(set) var items: [ShelfItem] = []`
  - `@Published var isTargeted: Bool = false`
- **Key Methods**:
  - `addURLs(_ urls: [URL])`: Appends files, deduplicates by URL path, validates accessibility, persists paths.
  - `remove(id: UUID)`: Deletes item from shelf.
  - `clearAll()`: Clears all items.
  - `open(item: ShelfItem)`: Calls `NSWorkspace.shared.open(item.url)`.
  - `revealInFinder(item: ShelfItem)`: Calls `NSWorkspace.shared.activateFileViewerSelecting([item.url])`.
  - `loadPersisted()` / `savePersisted()`: Reads and writes bookmark data/paths in `UserDefaults`.

---

### 3.4 User Interface & Interactions

#### Active Tab Management
```swift
enum NotchActiveTab: String, CaseIterable, Identifiable {
    case nowPlaying = "Now Playing"
    case shelf = "Drop Shelf"
    var id: String { rawValue }
}
```

#### Panel Header (`NotchPanelView.swift`)
- When panel is expanded, top section displays a compact segmented capsule:
  - Left: Music note icon + "Playing"
  - Right: Tray/Folder icon + "Shelf" + Badge count if `items.count > 0`.
- Tapping switches `activeTab` with a smooth spring animation.

#### Drop Shelf View (`DropShelfView.swift`)
- **Drop Target Overlay**:
  - Uses `.onDrop(of: [.fileURL], isTargeted: $shelf.isTargeted) { providers in ... }`.
  - When `isTargeted == true` or empty: Displays glowing dashed border card: *"Drop files here to hold"* with clear visual feedback.
- **Item Carousel**:
  - Horizontal scroll view of cards for staged files.
  - Each card displays:
    - 36x36 system file icon via `NSWorkspace.shared.icon(forFile:)`.
    - File name truncated with `.middle` line limit.
    - Human-readable file size.
    - Hover dismiss button (`✕`).
  - **Drag Out Support**:
    - Each card attaches `.onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }`.
    - Allows dragging files from the Notch into any other Mac app.
- **Footer Controls**:
  - Summary count (e.g. "3 items") and a "Clear All" button.

#### Drag & Drop Event Dispatching
- `NotchOverlayWindow` explicitly registers for dragged types:
  ```swift
  registerForDraggedTypes([.fileURL])
  ```
- When `NotchHoverMonitor` detects `.leftMouseDragged` into `enterRegion`:
  - State machine transitions to `.expanding`.
  - `activeTab` automatically flips to `.shelf`.
  - `window.setInteractive(true)` ensures drag events are delivered to SwiftUI's `.onDrop`.

---

## 4. Error Handling & Edge Cases

1. **Broken File Links**: If a staged file is moved or deleted in Finder, `ShelfItem.exists` returns `false`. Staged cards display a missing indicator or are automatically removed on next shelf load.
2. **Music / Spotify Authorization Revocation**: Gracefully handled via `NowPlayingAuthorization.needsPermission` without crashing or freezing.
3. **Double Dragging / Self Drop**: If a file is dragged out of the shelf and dropped back into the shelf, deduplication ignores already staged URLs.
4. **App Sandbox & Permissions**: App is non-sandboxed (`LSUIElement` utility); standard file URLs can be accessed and dragged freely.
