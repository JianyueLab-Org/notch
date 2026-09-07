//
//  MediaRemoteNowPlayingSource.swift
//  NotchNotch
//
//  Turns MediaRemote's dictionaries into `NowPlaying`. All the awkward
//  real-world behaviour of that framework is absorbed here.
//

import AppKit
import OSLog

@MainActor
final class MediaRemoteNowPlayingSource: NowPlayingSource {

    var onChange: ((NowPlaying?) -> Void)?

    var isAvailable: Bool { MediaRemoteBridge.isAvailable }

    /// MediaRemote never prompts — it simply returns an empty dictionary to
    /// callers it does not trust, which is why this reports `.notRequired`
    /// even when it is in practice returning nothing.
    let authorization: NowPlayingAuthorization = .notRequired

    func requestAuthorization() {}

    private var observers: [NSObjectProtocol] = []
    private var refreshTask: Task<Void, Never>?
    private var artworkRetryTask: Task<Void, Never>?

    /// Artwork arrives late (see `refresh`), so we hold the last decoded image
    /// keyed by MediaRemote's artwork identifier and reuse it until the
    /// identifier actually changes. This is also what stops us re-decoding a
    /// 100 KB JPEG on every unrelated update.
    private var artworkCache: (identifier: String, image: NSImage)?

    /// Only used to keep logging low-volume: a `notice` per track change is
    /// useful in a bug report, a `notice` per progress update is noise.
    private var lastLoggedTitle: String??

    // MARK: - Lifecycle

    func start() {
        guard isAvailable else {
            Log.media.error("media: MediaRemote unavailable — now playing disabled")
            onChange?(nil)
            return
        }

        MediaRemoteBridge.registerForNotifications()
        for name in [MediaRemoteBridge.infoDidChange, MediaRemoteBridge.isPlayingDidChange] {
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            }
            observers.append(token)
        }

        scheduleRefresh(delay: .zero)
        Log.media.notice("media: MediaRemote source started")
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        refreshTask?.cancel(); refreshTask = nil
        artworkRetryTask?.cancel(); artworkRetryTask = nil
        Log.media.notice("media: MediaRemote source stopped")
    }

    func send(_ command: MediaCommand) {
        let raw: MediaRemoteBridge.RawCommand = switch command {
        case .togglePlayPause: .togglePlayPause
        case .nextTrack: .nextTrack
        case .previousTrack: .previousTrack
        }
        MediaRemoteBridge.send(raw)
        // Don't wait for the notification: the transport should feel instant.
        // The authoritative state lands a moment later and overwrites this.
        scheduleRefresh(delay: .milliseconds(120))
    }

    // MARK: - Refresh

    /// A single change produces a burst of four notifications, so every refresh
    /// is coalesced rather than run per-notification.
    private func scheduleRefresh(delay: Duration = .milliseconds(60)) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            await self.refresh()
        }
    }

    private func refresh() async {
        let info = await MediaRemoteBridge.nowPlayingInfo()
        guard !info.isEmpty else {
            artworkCache = nil
            logTrackChange(nil)
            onChange?(nil)
            return
        }

        async let playingValue = MediaRemoteBridge.isPlaying()
        async let bundleValue = MediaRemoteBridge.nowPlayingClientBundleIdentifier()
        let (playing, bundle) = await (playingValue, bundleValue)

        let identifier = info.artworkIdentifier
        let artwork = resolveArtwork(data: info.artworkData, identifier: identifier)

        // GOTCHA: artwork is delivered LAZILY. The first `nowPlayingInfo` after
        // a track change carries the artwork's identifier, width, height and
        // MIME type but NOT the bytes — those show up on a later call, a few
        // hundred milliseconds on. So an update with no bytes must never be
        // read as "this track has no artwork"; we keep the identifier and come
        // back for it once.
        if artwork == nil, identifier != nil {
            scheduleArtworkRetry()
        }

        let rate = info.playbackRate ?? (playing ? 1 : 0)
        let track = NowPlaying(
            title: info.title ?? "",
            artist: info.artist ?? "",
            album: info.album ?? "",
            isPlaying: playing,
            duration: info.duration ?? 0,
            reportedElapsed: info.elapsed ?? 0,
            // Extrapolating progress needs the instant the snapshot was taken.
            // MediaRemote supplies it; falling back to "now" is close enough.
            reportedAt: info.timestamp ?? Date(),
            playbackRate: playing ? rate : 0,
            artworkIdentifier: identifier,
            artwork: artwork,
            clientBundleIdentifier: bundle)

        logTrackChange(track.title)
        Log.media.debug("""
            media: \(track.title, privacy: .public) — \(track.artist, privacy: .public) \
            playing=\(playing, privacy: .public) artwork=\(artwork != nil, privacy: .public)
            """)
        onChange?(track)
    }

    private func logTrackChange(_ title: String?) {
        guard lastLoggedTitle != .some(title) else { return }
        lastLoggedTitle = .some(title)
        if let title {
            Log.media.notice("media: now playing \(title, privacy: .public)")
        } else {
            Log.media.notice("media: no now-playing info (empty dictionary from MediaRemote)")
        }
    }

    private func scheduleArtworkRetry() {
        artworkRetryTask?.cancel()
        artworkRetryTask = Task { [weak self] in
            try? await Task.sleep(for: NotchConfiguration.artworkRetryDelay)
            guard !Task.isCancelled, let self else { return }
            await self.refresh()
        }
    }

    // MARK: - Artwork

    private func resolveArtwork(data: Data?, identifier: String?) -> NSImage? {
        if let identifier, let cached = artworkCache, cached.identifier == identifier {
            return cached.image
        }
        // Decoding ~100 KB of JPEG on the main actor is a fraction of a frame
        // and only happens on a track change, so it is not worth offloading.
        guard let data, let image = NSImage(data: data) else {
            return nil
        }
        if let identifier {
            artworkCache = (identifier, image)
        }
        return image
    }

    deinit {
        refreshTask?.cancel()
        artworkRetryTask?.cancel()
    }
}
