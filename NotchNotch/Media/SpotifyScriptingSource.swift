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
    private var script: NSAppleScript?
    private var artworkCache: (url: String, image: NSImage)?
    private var artworkTask: Task<Void, Never>?
    private var lastLoggedTitle: String??
    private var didLogRawDuration = false

    private static var isSpotifyRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    // MARK: - Lifecycle

    func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                try? await Task.sleep(for: NotchConfiguration.spotifyPollInterval)
            }
        }
        Log.media.notice("media: Spotify scripting source started (running=\(Self.isSpotifyRunning, privacy: .public))")
    }

    func stop() {
        pollTask?.cancel(); pollTask = nil
        artworkTask?.cancel(); artworkTask = nil
        Log.media.notice("media: Spotify scripting source stopped")
    }

    func send(_ command: MediaCommand) {
        guard Self.isSpotifyRunning else { return }
        let verb = switch command {
        case .togglePlayPause: "playpause"
        case .nextTrack: "next track"
        case .previousTrack: "previous track"
        }
        _ = run("tell application id \"\(Self.bundleIdentifier)\" to \(verb)")
        // Spotify updates its state a beat after the command lands.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            await self?.tick()
        }
    }

    /// Raise the system consent dialog deliberately. This one *does* block
    /// while the dialog is up, which is acceptable because it only happens on
    /// an explicit button press rather than on a background poll.
    func requestAuthorization() {
        guard Self.isSpotifyRunning else {
            Log.media.notice("media: cannot request Spotify automation — Spotify is not running")
            return
        }
        Task { [weak self] in
            guard let self else { return }
            _ = await self.permissionStatus(askUserIfNeeded: true)
            await self.tick()
        }
    }

    // MARK: - Polling

    private func tick() async {
        guard Self.isSpotifyRunning else {
            report(nil)
            return
        }
        // GOTCHA: sending an Apple event to an app we have not been authorised
        // for BLOCKS the calling thread while macOS shows the consent dialog —
        // and NSAppleScript must run on the main thread, so a naive poll would
        // freeze the whole overlay until the user answered. Ask TCC what the
        // answer already is, without prompting, and only script when allowed.
        switch await permissionStatus(askUserIfNeeded: false) {
        case noErr:
            if authorization != .granted {
                authorization = .granted
                Log.media.notice("media: Spotify automation permitted")
            }
        case OSStatus(errAEEventWouldRequireUserConsent):
            setNeedsPermission("NotchNotch needs permission to control Spotify.")
            return
        case OSStatus(errAEEventNotPermitted):
            setNeedsPermission("Allow NotchNotch to control Spotify in System Settings › Privacy & Security › Automation.")
            return
        case OSStatus(procNotFound):
            report(nil)
            return
        default:
            break // fall through and let the script surface the error
        }

        guard let descriptor = run(Self.readScript) else { return }
        report(makeTrack(from: descriptor))
    }

    /// Queries — and optionally raises — the Automation consent for Spotify.
    /// Runs off the main actor to avoid freezing the UI thread if TCCD blocks.
    private func permissionStatus(askUserIfNeeded: Bool) async -> OSStatus {
        await Task.detached(priority: .userInitiated) {
            let target = NSAppleEventDescriptor(bundleIdentifier: Self.bundleIdentifier)
            guard let aeDesc = target.aeDesc else { return OSStatus(procNotFound) }
            return withUnsafePointer(to: aeDesc.pointee) { pointer in
                AEDeterminePermissionToAutomateTarget(pointer, typeWildCard, typeWildCard, askUserIfNeeded)
            }
        }.value
    }

    private func setNeedsPermission(_ message: String) {
        let next = NowPlayingAuthorization.needsPermission(message)
        if authorization != next {
            authorization = next
            Log.media.notice("media: Spotify automation not granted — \(message, privacy: .public)")
        }
        report(nil)
    }

    /// A list is returned rather than a delimited string so that a track name
    /// containing the delimiter cannot corrupt the parse.
    ///
    /// `player state` is compared against the enum constants instead of being
    /// coerced with `as text`, which is not reliable across Spotify builds.
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
            set au to ""
            try
                set au to artwork url of t
            end try
            return {name of t, artist of t, album of t, (duration of t) as text, pos as text, st, au}
        on error
            return {"", "", "", "0", "0", st, ""}
        end try
    end tell
    """

    private func run(_ source: String) -> NSAppleEventDescriptor? {
        // NSAppleScript is main-thread-only and blocks on the Apple event round
        // trip. It is a handful of milliseconds against a healthy Spotify, which
        // is why this is not offloaded — but it is also why the polling interval
        // is lazy rather than per-frame.
        let compiled: NSAppleScript?
        if source == Self.readScript {
            if script == nil { script = NSAppleScript(source: source) }
            compiled = script
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
            Log.media.notice("media: Spotify automation permitted")
        }
        return result
    }

    private func handle(_ error: NSDictionary) {
        let code = error[NSAppleScript.errorNumber] as? Int ?? 0
        switch code {
        case -1743:
            // errAEEventNotPermitted — the user declined Automation, or has not
            // been asked yet and the prompt was suppressed.
            if !authorization.isBlocked {
                authorization = .needsPermission(
                    "Allow NotchNotch to control Spotify in System Settings › Privacy & Security › Automation.")
                Log.media.error("media: Spotify automation denied (-1743) — falling back")
            }
        case -600, -609:
            // Spotify quit between our running-check and the event.
            report(nil)
        default:
            Log.media.error("""
                media: Spotify AppleScript error \(code, privacy: .public): \
                \(error[NSAppleScript.errorMessage] as? String ?? "?", privacy: .public)
                """)
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
        let rawDuration = Double(field(4)) ?? 0
        let position = Double(field(5)) ?? 0
        let state = field(6)
        let artworkURL = field(7)

        guard !title.isEmpty || !artist.isEmpty else { return nil }

        if !didLogRawDuration {
            didLogRawDuration = true
            Log.media.notice("media: Spotify raw duration=\(rawDuration, privacy: .public) position=\(position, privacy: .public)")
        }

        let isPlaying = state == "playing"
        let duration = Self.normalisedDuration(rawDuration, position: position)

        if !artworkURL.isEmpty { fetchArtworkIfNeeded(artworkURL) }

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
            artwork: artworkCache?.url == artworkURL ? artworkCache?.image : nil,
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
        guard artworkCache?.url != urlString, let url = URL(string: urlString) else { return }
        artworkTask?.cancel()
        artworkTask = Task { [weak self] in
            // URLSession does the work off the main actor for us; no @concurrent
            // needed, and no reason to hand-roll a queue.
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = NSImage(data: data),
                  !Task.isCancelled,
                  let self else { return }
            self.artworkCache = (urlString, image)
            // Re-emit so the panel picks the artwork up now that it exists.
            await self.tick()
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
