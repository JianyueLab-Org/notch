//
//  SpotifyScriptingSource.swift
//  NotchNotch
//
//  Reads and controls Spotify over AppleScript. Richer and far less fragile
//  than scraping Control Center's Accessibility tree: we get title, artist,
//  album, duration, live position, real transport state and an artwork URL,
//  all from a documented scripting interface rather than a UI surface.
//
//  Property names, types and units below come from Spotify's own scripting
//  definition (`sdef /Applications/Spotify.app`), not from folklore.
//
//  Requires the "Automation" permission (per target app), which macOS prompts
//  for on the first Apple event. `NSAppleEventsUsageDescription` must be in
//  Info.plist or the request is denied outright.
//

import AppKit
import CoreServices
import OSLog

@MainActor
final class SpotifyScriptingSource: NowPlayingSource {

    nonisolated static let bundleIdentifier = "com.spotify.client"

    var onChange: ((NowPlaying?) -> Void)?

    private(set) var authorization: NowPlayingAuthorization = .notRequired

    /// Only meaningful when Spotify is actually running — we never want to be
    /// the reason it launches.
    var isAvailable: Bool { Self.isSpotifyRunning && !authorization.isBlocked }

    private var pollTask: Task<Void, Never>?
    /// `image == nil` is a cached miss, so a failing URL is not re-downloaded
    /// on every poll.
    private var artworkCache: (url: String, image: NSImage?)?
    private var artworkTask: Task<Void, Never>?
    private var artworkFetchingURL: String?
    private var lastLoggedTitle: String??
    private var didLogRawDuration = false

    /// A read is a cross-process round trip that can take up to the script
    /// timeout. Extra ticks (commands, artwork arrival) arriving meanwhile are
    /// folded into one re-read instead of queueing behind it.
    private var isReading = false
    private var rereadRequested = false

    /// `isTerminated` matters during Cmd-Q: the app is still listed while it
    /// quits, and an Apple event sent then would relaunch it.
    private static var isSpotifyRunning: Bool {
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
        Log.media.notice("media: Spotify scripting source started (running=\(Self.isSpotifyRunning, privacy: .public))")
    }

    func stop() {
        pollTask?.cancel(); pollTask = nil
        artworkTask?.cancel(); artworkTask = nil
        artworkFetchingURL = nil
        Log.media.notice("media: Spotify scripting source stopped")
    }

    func send(_ command: MediaCommand) {
        guard Self.isSpotifyRunning else { return }
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
            // Spotify updates its state a beat after the command lands.
            try? await Task.sleep(for: .milliseconds(250))
            await self.tick()
        }
    }

    /// Raise the system consent dialog deliberately. The Apple event that
    /// triggers it runs on the script queue, so the overlay stays live while
    /// the dialog is up.
    func requestAuthorization() {
        guard Self.isSpotifyRunning else {
            Log.media.notice("media: cannot request Spotify automation — Spotify is not running")
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
        guard Self.isSpotifyRunning else {
            report(nil)
            return
        }

        switch await AppleScriptExecutor.shared.run(Self.readScript) {
        case .success(let reply):
            markGranted()
            report(makeTrack(from: reply))
        case .failure(let code, let message):
            handleFailure(code: code, message: message)
            // Never leave the last good track on screen: a failed read means
            // we no longer know what is playing.
            report(nil)
        }
    }

    /// Wraps a script so it neither launches Spotify nor waits on it for the
    /// default two minutes. The `is running` check is inside the script
    /// because Spotify can quit between our Swift-side check and the event.
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

    /// A list is returned rather than a delimited string so that a track name
    /// containing the delimiter cannot corrupt the parse.
    ///
    /// `player state` is compared against the enum constants instead of being
    /// coerced with `as text`, which is not reliable across Spotify builds.
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
            set au to ""
            try
                set au to artwork url of t
            end try
            return {name of t, artist of t, album of t, (duration of t) as text, pos as text, playbackStatus, au}
        on error
            return {"", "", "", "0", "0", playbackStatus, ""}
        end try
    end tell
    """)

    private func markGranted() {
        if authorization != .granted {
            authorization = .granted
            Log.media.notice("media: Spotify automation permitted")
        }
    }

    private func handleFailure(code: Int, message: String) {
        switch code {
        case -1743, -1744:
            // errAEEventNotPermitted — the user declined Automation, or has not
            // been asked yet and the prompt was suppressed.
            if !authorization.isBlocked {
                authorization = .needsPermission(.spotifyAutomation)
                Log.media.error("media: Spotify automation denied (\(code, privacy: .public)) — falling back")
            }
        case -600, -609:
            // Spotify quit between our running-check and the event.
            break
        case -1712:
            Log.media.error("media: Spotify AppleScript timed out")
        default:
            Log.media.error("""
                media: Spotify AppleScript error \(code, privacy: .public): \
                \(message, privacy: .public)
                """)
        }
    }

    // MARK: - Parsing

    private func makeTrack(from reply: AppleScriptReply) -> NowPlaying? {
        // The guard wrapper returns an empty list when Spotify is not running.
        guard reply.strings.count >= 7 else { return nil }
        let title = reply.string(at: 0)
        let artist = reply.string(at: 1)
        let album = reply.string(at: 2)
        let rawDuration = Double(reply.string(at: 3)) ?? 0
        let position = Double(reply.string(at: 4)) ?? 0
        let state = reply.string(at: 5)
        let artworkURL = reply.string(at: 6)

        guard !title.isEmpty || !artist.isEmpty else { return nil }

        if !didLogRawDuration {
            didLogRawDuration = true
            Log.media.notice("media: Spotify raw duration=\(rawDuration, privacy: .public) position=\(position, privacy: .public)")
        }

        let isPlaying = state.lowercased().contains("play") || state.contains("kPSP")
        let duration = Self.normalisedDuration(rawDuration, position: position)

        if !artworkURL.isEmpty { fetchArtworkIfNeeded(artworkURL) }
        let artwork = artworkCache?.url == artworkURL ? artworkCache?.image : nil

        Log.media.notice("media: Spotify parsed '\(title, privacy: .public)' isPlaying=\(isPlaying, privacy: .public) state='\(state, privacy: .public)' hasArtwork=\(artwork != nil, privacy: .public)")

        return NowPlaying(
            title: title,
            artist: artist,
            album: album,
            isPlaying: isPlaying,
            duration: duration,
            reportedElapsed: position,
            reportedAt: Date(),
            // Position is a live read, so the view can extrapolate between
            // polls exactly as it does for any other backend.
            playbackRate: isPlaying ? 1 : 0,
            artworkIdentifier: artworkURL.isEmpty ? nil : artworkURL,
            artwork: artwork,
            clientBundleIdentifier: Self.bundleIdentifier)
    }

    /// Spotify's sdef declares `duration` as "the length of the track in
    /// seconds", but the app has long returned milliseconds. Rather than pick a
    /// side, normalise: a value that would mean a track longer than three hours,
    /// or one that is somehow behind the (definitely-seconds) player position,
    /// is milliseconds.
    static func normalisedDuration(_ raw: Double, position: Double) -> Double {
        guard raw > 0 else { return 0 }
        let looksLikeMilliseconds = raw > 10_800 || (position > 0 && position > raw)
        return looksLikeMilliseconds ? raw / 1000 : raw
    }

    // MARK: - Artwork

    private func fetchArtworkIfNeeded(_ urlString: String) {
        guard artworkCache?.url != urlString, artworkFetchingURL != urlString else { return }
        guard let url = URL(string: urlString) else {
            artworkCache = (urlString, nil)
            return
        }
        artworkTask?.cancel()
        artworkFetchingURL = urlString
        artworkTask = Task { [weak self] in
            var image: NSImage?
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                image = NSImage(data: data)
                if image == nil {
                    Log.media.error("media: Spotify failed to decode artwork image from \(urlString, privacy: .public)")
                } else {
                    Log.media.notice("media: Spotify successfully fetched artwork (\(data.count, privacy: .public) bytes)")
                }
            } catch {
                Log.media.error("media: Spotify artwork download failed: \(error.localizedDescription, privacy: .public)")
            }
            guard !Task.isCancelled, let self else { return }
            self.artworkFetchingURL = nil
            // A miss is cached too, so the URL is not retried every poll.
            self.artworkCache = (urlString, image)
            // Re-emit so the panel picks the artwork up now that it exists.
            if image != nil { await self.tick() }
        }
    }

    private func report(_ track: NowPlaying?) {
        if lastLoggedTitle != .some(track?.title) {
            lastLoggedTitle = .some(track?.title)
            Log.media.notice("media: Spotify \(track?.title ?? "(nothing)", privacy: .public)")
        }
        onChange?(track)
    }

    deinit {
        pollTask?.cancel()
        artworkTask?.cancel()
    }
}
