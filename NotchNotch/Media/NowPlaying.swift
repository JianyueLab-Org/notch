//
//  NowPlaying.swift
//  NotchNotch
//
//  What the panel needs to know about the current track. Deliberately free of
//  any MediaRemote vocabulary so a different backend can produce it.
//

import AppKit

struct NowPlaying: Equatable {

    var title: String
    var artist: String
    var album: String
    var isPlaying: Bool

    var duration: TimeInterval
    /// Playback position **as of `reportedAt`** — not right now.
    var reportedElapsed: TimeInterval
    var reportedAt: Date
    /// 1.0 while playing, 0 while paused; also covers scrubbing speeds.
    var playbackRate: Double

    var artworkIdentifier: String?
    var artwork: NSImage?
    var clientBundleIdentifier: String?

    /// Playback position extrapolated to `date`.
    ///
    /// The backend reports a snapshot plus the instant it was taken, so the
    /// progress bar can run smoothly off a single update instead of us polling
    /// the framework several times a second.
    func elapsed(at date: Date) -> TimeInterval {
        guard playbackRate != 0 else { return reportedElapsed }
        let projected = reportedElapsed + date.timeIntervalSince(reportedAt) * playbackRate
        return min(max(projected, 0), duration > 0 ? duration : projected)
    }

    func progress(at date: Date) -> Double {
        guard duration > 0 else { return 0 }
        return min(max(elapsed(at: date) / duration, 0), 1)
    }

    var hasTrack: Bool { !title.isEmpty || !artist.isEmpty }
}

extension TimeInterval {
    /// mm:ss, the only format a transport bar ever needs.
    var clockString: String {
        guard isFinite, self >= 0 else { return "--:--" }
        let total = Int(self.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
