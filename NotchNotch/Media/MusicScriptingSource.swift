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

    nonisolated static let bundleIdentifier = "com.apple.Music"

    var onChange: ((NowPlaying?) -> Void)?

    private(set) var authorization: NowPlayingAuthorization = .notRequired

    var isAvailable: Bool { Self.isMusicRunning && !authorization.isBlocked }

    private var pollTask: Task<Void, Never>?
    /// Keyed by the track id the artwork script itself read, not the one that
    /// triggered the fetch, so a skip mid-fetch cannot attach the wrong cover.
    /// `image == nil` is a cached miss for an artless track.
    private var artworkCache: (trackId: String, image: NSImage?)?
    private var artworkTask: Task<Void, Never>?
    private var artworkFetchingId: String?
    private var lastLoggedTitle: String??

    /// See SpotifyScriptingSource: overlapping ticks fold into one re-read.
    private var isReading = false
    private var rereadRequested = false

    /// `isTerminated` matters during Cmd-Q: an Apple event sent while Music is
    /// quitting would relaunch it.
    private static var isMusicRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .contains { !$0.isTerminated }
    }

    // MARK: - Lifecycle

    func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                let interval = self.authorization.isBlocked
                    ? NotchConfiguration.accessibilityAuthorizationPollInterval
                    : NotchConfiguration.spotifyPollInterval
                try? await Task.sleep(for: interval)
            }
        }
        Log.media.notice("media: Music scripting source started (running=\(Self.isMusicRunning, privacy: .public))")
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        artworkTask?.cancel()
        artworkTask = nil
        artworkFetchingId = nil
        Log.media.notice("media: Music scripting source stopped")
    }

    func send(_ command: MediaCommand) {
        guard Self.isMusicRunning else { return }
        let verb = switch command {
        case .togglePlayPause: "playpause"
        case .nextTrack: "next track"
        case .previousTrack: "previous track"
        }
        let source = Self.guarded("tell application id \"\(Self.bundleIdentifier)\" to \(verb)")
        Task { [weak self] in
            let outcome = await AppleScriptExecutor.shared.run(source)
            guard let self else { return }
            if case .failure(let code, let message) = outcome {
                self.handleFailure(code: code, message: message)
            }
            try? await Task.sleep(for: .milliseconds(250))
            await self.tick()
        }
    }

    func requestAuthorization() {
        guard Self.isMusicRunning else {
            Log.media.notice("media: cannot request Music automation — Music is not running")
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        authorization = .notRequired
        Task { [weak self] in
            await self?.tick()
        }
    }

    // MARK: - Polling

    private func tick() async {
        guard !isReading else {
            rereadRequested = true
            return
        }
        isReading = true
        defer { isReading = false }
        repeat {
            rereadRequested = false
            await read()
        } while rereadRequested && !Task.isCancelled
    }

    private func read() async {
        guard Self.isMusicRunning else {
            report(nil)
            return
        }

        switch await AppleScriptExecutor.shared.run(Self.readScript) {
        case .success(let reply):
            markGranted()
            report(makeTrack(from: reply))
        case .failure(let code, let message):
            handleFailure(code: code, message: message)
            // A failed read means we no longer know what is playing; never
            // leave the last good track on screen.
            report(nil)
        }
    }

    /// Never launch Music and never wait on it for the default two minutes.
    /// The `is running` check is inside the script because Music can quit
    /// between our Swift-side check and the event.
    private static func guarded(_ body: String) -> String {
        """
        if application id "\(bundleIdentifier)" is running then
            with timeout of \(NotchConfiguration.appleScriptTimeoutSeconds) seconds
                \(body)
            end timeout
        end if
        return {}
        """
    }

    private static let readScript = guarded("""
    tell application id "\(bundleIdentifier)"
        set ps to "stopped"
        try
            set ps to (player state as string)
        end try
        set playbackStatus to "stopped"
        if ps is "playing" or player state is playing then
            set playbackStatus to "playing"
        else if ps is "paused" or player state is paused then
            set playbackStatus to "paused"
        else if ps is not "" then
            set playbackStatus to ps
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
            return {trName, trArtist, trAlbum, trDur as text, pos as text, playbackStatus, trId}
        on error
            return {"", "", "", "0", "0", playbackStatus, ""}
        end try
    end tell
    """)

    /// Returns the id alongside the bytes so the caller can check the track
    /// did not change between the read and this fetch.
    private static let rawArtworkScript = guarded("""
    tell application id "\(bundleIdentifier)"
        try
            set t to current track
            set trId to (id of t) as text
            if (count of artworks of t) > 0 then
                return {trId, raw data of artwork 1 of t}
            end if
            return {trId, ""}
        end try
        return {}
    end tell
    """)

    private func markGranted() {
        if authorization != .granted {
            authorization = .granted
        }
    }

    private func handleFailure(code: Int, message: String) {
        switch code {
        case -1743, -1744:
            if !authorization.isBlocked {
                authorization = .needsPermission(.musicAutomation)
                Log.media.error("media: Music automation denied (\(code, privacy: .public))")
            }
        case -600, -609:
            break
        case -1712:
            Log.media.error("media: Music AppleScript timed out")
        default:
            Log.media.error("media: Music AppleScript error \(code, privacy: .public): \(message, privacy: .public)")
        }
    }

    // MARK: - Parsing

    private func makeTrack(from reply: AppleScriptReply) -> NowPlaying? {
        // The guard wrapper returns an empty list when Music is not running.
        guard reply.strings.count >= 7 else { return nil }
        let title = reply.string(at: 0)
        let artist = reply.string(at: 1)
        let album = reply.string(at: 2)
        let duration = Double(reply.string(at: 3)) ?? 0
        let position = Double(reply.string(at: 4)) ?? 0
        let state = reply.string(at: 5)
        let trackId = reply.string(at: 6)

        guard !title.isEmpty || !artist.isEmpty else { return nil }

        let isPlaying = state.lowercased().contains("play") || state.contains("kPSP")

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
        guard artworkCache?.trackId != trackId, artworkFetchingId != trackId else { return }
        artworkTask?.cancel()
        artworkFetchingId = trackId
        artworkTask = Task { [weak self] in
            let outcome = await AppleScriptExecutor.shared.run(Self.rawArtworkScript)
            guard !Task.isCancelled, let self else { return }
            self.artworkFetchingId = nil
            guard case .success(let reply) = outcome, reply.strings.count >= 2 else {
                // Script failure: cache the miss for the requested track so the
                // fetch is not repeated every poll.
                self.artworkCache = (trackId, nil)
                return
            }
            let fetchedId = reply.string(at: 0)
            let data = reply.data[1]
            let image = data.isEmpty ? nil : NSImage(data: data)
            self.artworkCache = (fetchedId, image)
            if image != nil || fetchedId != trackId {
                await self.tick()
            }
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
