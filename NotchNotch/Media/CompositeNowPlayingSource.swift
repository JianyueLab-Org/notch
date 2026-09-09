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
        // the user for — never nag about a permission we do not need.
        if activeIndex != nil { return .granted }
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
        latest[index] = track
        // Priority 1: Backend that is actively playing audio
        let playingWinner = latest.indices.first { latest[$0]?.isPlaying == true && latest[$0]?.hasTrack == true }
        // Priority 2: Backend that has any track info
        let trackWinner = latest.indices.first { latest[$0]?.hasTrack == true }

        let winner = playingWinner ?? trackWinner
        if winner != activeIndex {
            activeIndex = winner
            let name = winner.map { String(describing: type(of: children[$0])) } ?? "none"
            Log.media.notice("media: active backend -> \(name, privacy: .public)")
        }
        if var bestTrack = winner.flatMap({ latest[$0] }) {
            if bestTrack.artwork == nil {
                for other in latest where other?.title == bestTrack.title && other?.artwork != nil {
                    bestTrack.artwork = other?.artwork
                    break
                }
            }
            if bestTrack.duration <= 0 {
                for other in latest where other?.title == bestTrack.title && (other?.duration ?? 0) > 0 {
                    bestTrack.duration = other?.duration ?? 0
                    break
                }
            }
            onChange?(bestTrack)
        } else {
            onChange?(nil)
        }
    }
}
