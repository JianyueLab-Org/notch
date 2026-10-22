//
//  CompositeNowPlayingSource.swift
//  NotchNotch
//
//  Runs several backends at once and publishes the best answer.
//
//  Priority order is the array order: Spotify's scripting interface first
//  because it gives real metadata, artwork and transport state, then the
//  Accessibility reader as a fallback for everything else (browsers, Music,
//  anything that only shows up in Control Center).
//
//  Commands are routed to whichever backend is currently supplying the track,
//  so pressing pause hits Spotify's `playpause` when Spotify is playing and
//  falls back to a synthesised media key otherwise.
//

import Foundation
import OSLog

@MainActor
final class CompositeNowPlayingSource: NowPlayingSource {

    var onChange: ((NowPlaying?) -> Void)?

    private let children: [any NowPlayingSource]
    /// Last value seen from each child, positionally aligned with `children`.
    private var latest: [NowPlaying?]
    private var activeIndex: Int?

    init(children: [any NowPlayingSource]) {
        self.children = children
        self.latest = Array(repeating: nil, count: children.count)
    }

    var isAvailable: Bool { children.contains { $0.isAvailable } }

    var authorization: NowPlayingAuthorization {
        // If something is actually producing a track, there is nothing to ask
        // the user for — never nag about a permission we do not need. A
        // blocked backend never counts as producing one.
        if let activeIndex, !children[activeIndex].authorization.isBlocked { return .granted }
        // Otherwise surface the highest-priority actionable request.
        for child in children where child.authorization.isBlocked {
            return child.authorization
        }
        return children.contains { $0.isAvailable } ? .granted : .notRequired
    }

    // MARK: - Lifecycle

    func start() {
        for (index, child) in children.enumerated() {
            child.onChange = { [weak self] track in
                self?.update(index: index, track: track)
            }
            child.start()
        }
        Log.media.notice("media: composite source started with \(self.children.count, privacy: .public) backend(s)")
    }

    func stop() {
        for child in children {
            child.stop()
            child.onChange = nil
        }
        latest = Array(repeating: nil, count: children.count)
        activeIndex = nil
    }

    func send(_ command: MediaCommand) {
        let target = activeIndex.map { children[$0] } ?? children.first { $0.isAvailable }
        target?.send(command)
    }

    func requestAuthorization() {
        // Ask only the backend that is actually blocked, so we raise one prompt
        // rather than every prompt the app could ever need.
        if let blocked = children.first(where: { $0.authorization.isBlocked }) {
            blocked.requestAuthorization()
            return
        }
        children.first?.requestAuthorization()
    }

    // MARK: - Merge

    private func update(index: Int, track: NowPlaying?) {
        // A backend that has lost its permission cannot vouch for the last
        // track it saw, so it drops out of the merge entirely.
        latest[index] = children[index].authorization.isBlocked ? nil : track
        // Priority 1: Backend that is actively playing audio.
        // Accessibility marks every Control Center match as playing, with no duration
        // and a zero rate. That guess must not beat an earlier backend that has the track.
        let playingWinner = latest.indices.first { index in
            guard let track = latest[index], track.isPlaying, track.hasTrack else { return false }
            if track.playbackRate == 0, track.duration <= 0,
               latest[..<index].contains(where: { $0?.hasTrack == true }) {
                return false
            }
            return true
        }
        // Priority 2: Backend that has any track info
        let trackWinner = latest.indices.first { latest[$0]?.hasTrack == true }

        let winner = playingWinner ?? trackWinner
        if winner != activeIndex {
            activeIndex = winner
            let name = winner.map { String(describing: type(of: children[$0])) } ?? "none"
            Log.media.notice("media: active backend -> \(name, privacy: .public)")
        }
        if var bestTrack = winner.flatMap({ latest[$0] }) {
            let sameTrack = latest.compactMap { $0 }.filter { Self.isSameTrack($0, bestTrack) }
            if bestTrack.artwork == nil, let artwork = sameTrack.lazy.compactMap(\.artwork).first {
                bestTrack.artwork = artwork
            }
            if bestTrack.duration <= 0, let duration = sameTrack.lazy.map(\.duration).first(where: { $0 > 0 }) {
                bestTrack.duration = duration
            }
            onChange?(bestTrack)
        } else {
            onChange?(nil)
        }
    }

    /// Backfill is only safe between reports of the same track. Title alone
    /// is not enough — covers and live versions share titles — so the artist
    /// must match too, and the album when both sides know it.
    private static func isSameTrack(_ lhs: NowPlaying, _ rhs: NowPlaying) -> Bool {
        func normalised(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        guard normalised(lhs.title) == normalised(rhs.title),
              normalised(lhs.artist) == normalised(rhs.artist) else { return false }
        let (lhsAlbum, rhsAlbum) = (normalised(lhs.album), normalised(rhs.album))
        return lhsAlbum.isEmpty || rhsAlbum.isEmpty || lhsAlbum == rhsAlbum
    }
}
