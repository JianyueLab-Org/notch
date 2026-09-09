//
//  NowPlayingView.swift
//  NotchNotch
//
//  Media player card matching the macOS notch aesthetic.
//

import SwiftUI

struct NowPlayingView: View {

    let track: NowPlaying
    let send: (MediaCommand) -> Void

    var body: some View {
        HStack(spacing: 12) {
            artwork
            VStack(alignment: .leading, spacing: 2) {
                titles
                Spacer(minLength: 6)
                transport
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
    }

    // MARK: - Components

    private var artwork: some View {
        Group {
            if let image = track.artwork {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.06)
                    Image(systemName: "music.note")
                        .font(.system(size: 26))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
        }
        .frame(width: 82, height: 82)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 5, y: 2)
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(track.title.isEmpty ? "Nothing Playing" : track.title)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(track.artist.isEmpty ? "Music / Spotify" : track.artist)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(1)
            Text(track.album.isEmpty ? (track.title.isEmpty ? "Ready to play" : track.artist) : track.album)
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.4))
                .lineLimit(1)
        }
    }

    private var transport: some View {
        HStack(spacing: 20) {
            button("backward.fill", size: 12) { send(.previousTrack) }
            button(track.isPlaying ? "pause.fill" : "play.fill", size: 16) { send(.togglePlayPause) }
            button("forward.fill", size: 12) { send(.nextTrack) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func button(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
