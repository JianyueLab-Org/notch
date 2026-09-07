//
//  NowPlayingView.swift
//  NotchNotch
//
//  The first real content module. Knows about `NowPlaying` and `MediaCommand`
//  and nothing else — no MediaRemote, no private API.
//

import SwiftUI

struct NowPlayingView: View {

    let track: NowPlaying
    let send: (MediaCommand) -> Void

    var body: some View {
        HStack(spacing: 16) {
            artwork
            VStack(alignment: .leading, spacing: 8) {
                titles
                progress
                transport
            }
        }
    }

    // MARK: - Pieces

    private var artwork: some View {
        Group {
            if let image = track.artwork {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                // Artwork is fetched lazily by the source, so this placeholder
                // is a normal transient state, not an error.
                ZStack {
                    Color.white.opacity(0.08)
                    Image(systemName: "music.note")
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
        }
        .frame(width: 84, height: 84)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.5), radius: 6, y: 3)
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(track.title.isEmpty ? "Unknown Track" : track.title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(track.artist)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
        }
    }

    private var progress: some View {
        // A TimelineView keeps the bar moving off a single snapshot, instead of
        // us polling MediaRemote several times a second. It only ticks while
        // the view is in the hierarchy, which is why NotchPanelView drops the
        // content entirely once collapsed.
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let date = track.isPlaying ? context.date : track.reportedAt
            VStack(spacing: 3) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.15))
                        Capsule()
                            .fill(.white.opacity(0.85))
                            .frame(width: proxy.size.width * track.progress(at: date))
                    }
                }
                .frame(height: 3)

                HStack {
                    Text(track.elapsed(at: date).clockString)
                    Spacer()
                    Text(track.duration.clockString)
                }
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
            }
        }
        .frame(height: 20)
    }

    private var transport: some View {
        HStack(spacing: 20) {
            button("backward.fill", size: 13) { send(.previousTrack) }
            button(track.isPlaying ? "pause.fill" : "play.fill", size: 17) { send(.togglePlayPause) }
            button("forward.fill", size: 13) { send(.nextTrack) }
        }
        .frame(maxWidth: .infinity)
    }

    private func button(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 24)
                .contentShape(Rectangle())
        }
        // Plain, or AppKit draws a full push-button chrome inside the notch.
        .buttonStyle(.plain)
    }
}
