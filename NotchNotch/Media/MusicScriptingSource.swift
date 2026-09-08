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
            guard let desc = self.run(Self.rawArtworkScript) else { return }
            let data = desc.data
            guard !data.isEmpty, let image = NSImage(data: data) else { return }
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
