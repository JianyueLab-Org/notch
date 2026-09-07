//
//  MediaRemoteBridge.swift
//  NotchNotch
//
//  ⚠️  PRIVATE API — raw MediaRemote access lives here and nowhere else.  ⚠️
//
//  Same safety rules as PrivateWindowElevation: symbols are resolved with
//  dlopen/dlsym at runtime rather than linked, so if Apple removes them the app
//  still launches and `isAvailable` simply goes false. Nothing here traps.
//
//  Everything below was verified empirically on macOS 27 rather than taken from
//  folklore — see the notes on each member.
//
//  This is the ONLY file that knows MediaRemote exists. `NowPlayingSource` is
//  the seam: writing an Accessibility-based source instead means adding one
//  file and changing one line in NotchWindowController.
//

import Darwin
import Foundation
import OSLog

nonisolated enum MediaRemoteBridge {

    // MARK: - Symbol resolution

    nonisolated(unsafe) private static let handle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY)

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let raw = dlsym(handle, name) else { return nil }
        return unsafeBitCast(raw, to: type)
    }

    private typealias InfoHandler = @convention(block) (CFDictionary?) -> Void
    private typealias GetInfoFn = @convention(c) (DispatchQueue, @escaping InfoHandler) -> Void
    private typealias BoolHandler = @convention(block) (Bool) -> Void
    private typealias IsPlayingFn = @convention(c) (DispatchQueue, @escaping BoolHandler) -> Void
    private typealias ClientHandler = @convention(block) (AnyObject?) -> Void
    private typealias GetClientFn = @convention(c) (DispatchQueue, @escaping ClientHandler) -> Void
    private typealias BundleIDFn = @convention(c) (AnyObject?) -> Unmanaged<CFString>?
    private typealias RegisterFn = @convention(c) (DispatchQueue) -> Void
    private typealias SendCommandFn = @convention(c) (Int32, CFDictionary?) -> Bool

    nonisolated(unsafe) private static let getInfo = symbol("MRMediaRemoteGetNowPlayingInfo", as: GetInfoFn.self)
    nonisolated(unsafe) private static let getIsPlaying = symbol("MRMediaRemoteGetNowPlayingApplicationIsPlaying", as: IsPlayingFn.self)
    nonisolated(unsafe) private static let getClient = symbol("MRMediaRemoteGetNowPlayingClient", as: GetClientFn.self)
    nonisolated(unsafe) private static let clientBundleID = symbol("MRNowPlayingClientGetBundleIdentifier", as: BundleIDFn.self)
    nonisolated(unsafe) private static let registerNotifications = symbol("MRMediaRemoteRegisterForNowPlayingNotifications", as: RegisterFn.self)
    nonisolated(unsafe) private static let sendCommand = symbol("MRMediaRemoteSendCommand", as: SendCommandFn.self)

    static var isAvailable: Bool { getInfo != nil && sendCommand != nil }

    // MARK: - Notifications
    //
    // Verified by observing NotificationCenter after registering: MediaRemote
    // posts FOUR names for a single change (Origin/Player/underscored variants).
    // We only subscribe to the canonical one and debounce anyway, but the
    // burst is the reason the debounce exists.

    static let infoDidChange = Notification.Name("kMRMediaRemoteNowPlayingInfoDidChangeNotification")
    static let isPlayingDidChange = Notification.Name("kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification")

    nonisolated(unsafe) private static var didRegister = false

    @MainActor
    static func registerForNotifications() {
        guard !didRegister, let registerNotifications else { return }
        didRegister = true
        registerNotifications(DispatchQueue.main)
        Log.media.notice("media: registered for MediaRemote notifications")
    }

    // MARK: - Reads
    //
    // The callbacks are handed to a background queue and bridged through a
    // continuation; resuming hops back to whichever actor awaited, so callers
    // stay on the main actor without us dispatching by hand.

    /// The info dictionary is `[String: Any]` and therefore not `Sendable`, so
    /// it is parsed into this on the callback's own queue and never crosses an
    /// isolation boundary. That also keeps every MediaRemote key string inside
    /// this file.
    nonisolated struct RawNowPlayingInfo: Sendable {
        var isEmpty = true
        var title: String?
        var artist: String?
        var album: String?
        var duration: Double?
        var elapsed: Double?
        var timestamp: Date?
        var playbackRate: Double?
        var artworkData: Data?
        var artworkIdentifier: String?

        init() {}

        init(dictionary info: [String: Any]) {
            isEmpty = info.isEmpty
            title = info[Key.title] as? String
            artist = info[Key.artist] as? String
            album = info[Key.album] as? String
            duration = info[Key.duration] as? Double
            elapsed = info[Key.elapsed] as? Double
            timestamp = info[Key.timestamp] as? Date
            playbackRate = info[Key.playbackRate] as? Double
            artworkData = info[Key.artworkData] as? Data
            // The identifier is a string on some players and a number on
            // others, so normalise it here rather than at every use site.
            artworkIdentifier = switch info[Key.artworkIdentifier] {
            case let value as String: value
            case let value as NSNumber: value.stringValue
            default: nil
            }
        }
    }

    static func nowPlayingInfo() async -> RawNowPlayingInfo {
        guard let getInfo else { return RawNowPlayingInfo() }
        return await withCheckedContinuation { continuation in
            getInfo(DispatchQueue.global()) { dictionary in
                continuation.resume(returning: RawNowPlayingInfo(
                    dictionary: (dictionary as? [String: Any]) ?? [:]))
            }
        }
    }

    static func isPlaying() async -> Bool {
        guard let getIsPlaying else { return false }
        return await withCheckedContinuation { continuation in
            getIsPlaying(DispatchQueue.global()) { playing in
                continuation.resume(returning: playing)
            }
        }
    }

    static func nowPlayingClientBundleIdentifier() async -> String? {
        guard let getClient, let clientBundleID else { return nil }
        return await withCheckedContinuation { continuation in
            getClient(DispatchQueue.global()) { client in
                let identifier = client.flatMap { clientBundleID($0)?.takeUnretainedValue() as String? }
                continuation.resume(returning: identifier)
            }
        }
    }

    // MARK: - Commands
    //
    // The standard MediaRemote command IDs. `play` (0) was verified to return
    // true against a live Spotify session; the transport three are the
    // long-established values and are exercised by the panel's buttons.

    enum RawCommand: Int32 {
        case play = 0
        case pause = 1
        case togglePlayPause = 2
        case nextTrack = 4
        case previousTrack = 5
    }

    @discardableResult
    static func send(_ command: RawCommand) -> Bool {
        guard let sendCommand else {
            Log.media.error("media: MRMediaRemoteSendCommand unavailable")
            return false
        }
        let ok = sendCommand(command.rawValue, nil)
        Log.media.debug("media: sent command \(command.rawValue, privacy: .public) -> \(ok, privacy: .public)")
        return ok
    }

    // MARK: - Info dictionary keys

    private enum Key {
        static let title = "kMRMediaRemoteNowPlayingInfoTitle"
        static let artist = "kMRMediaRemoteNowPlayingInfoArtist"
        static let album = "kMRMediaRemoteNowPlayingInfoAlbum"
        static let duration = "kMRMediaRemoteNowPlayingInfoDuration"
        static let elapsed = "kMRMediaRemoteNowPlayingInfoElapsedTime"
        static let timestamp = "kMRMediaRemoteNowPlayingInfoTimestamp"
        static let playbackRate = "kMRMediaRemoteNowPlayingInfoPlaybackRate"
        static let artworkData = "kMRMediaRemoteNowPlayingInfoArtworkData"
        static let artworkIdentifier = "kMRMediaRemoteNowPlayingInfoArtworkIdentifier"
    }
}
