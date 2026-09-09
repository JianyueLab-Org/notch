//
//  NowPlayingView.swift
//  NotchNotch
//
//  Media player card matching the macOS notch aesthetic.
//

import SwiftUI

struct NowPlayingView: View {

    let track: NowPlaying
    var authorization: NowPlayingAuthorization = .notRequired
    var onRequestAuthorization: (() -> Void)? = nil
    let send: (MediaCommand) -> Void

    var body: some View {
        HStack(spacing: 10) {
            artwork
            VStack(alignment: .leading, spacing: 2) {
                if !track.hasTrack, case .needsPermission(let message) = authorization {
                    permissionView(message: message)
                } else {
                    titles
                    Spacer(minLength: 2)
                    progressBar
                    Spacer(minLength: 2)
                    transport
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color(white: 0.11))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.15), Color.white.opacity(0.04)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.5
                        )
                )
        )
    }

    // MARK: - Components

    private var artwork: some View {
        Group {
            if let image = track.artwork {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 66, height: 66)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                    )
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.09), Color.white.opacity(0.03)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                        )

                    Image(systemName: !track.hasTrack && authorization.isBlocked ? "lock.shield.fill" : "music.note")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(
                            LinearGradient(
                                colors: !track.hasTrack && authorization.isBlocked
                                    ? [Color.orange.opacity(0.8), Color.orange.opacity(0.4)]
                                    : [Color.white.opacity(0.5), Color.white.opacity(0.25)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
            }
        }
        .frame(width: 66, height: 66)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
    }

    private func permissionView(message: String) -> some View {
        VStack(alignment: .leading, spacing: 2.5) {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.orange)
                Text("Permission Needed")
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            Text(message.contains("Music") ? "Allow Music in Automation" : "Allow Spotify in Automation")
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(1)
            Spacer(minLength: 2)
            HStack(spacing: 6) {
                if let onRequestAuthorization {
                    Button {
                        onRequestAuthorization()
                    } label: {
                        Text("Grant")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(
                                Capsule().fill(Color.accentColor)
                            )
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text("Settings")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 7.5))
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(
                        Capsule().fill(Color.white.opacity(0.16))
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 1.5) {
            Text(track.title.isEmpty ? "Nothing Playing" : track.title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(track.artist.isEmpty ? "Music / Spotify" : track.artist)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(1)
            Text(track.album.isEmpty ? (track.title.isEmpty ? "Ready to play" : track.artist) : track.album)
                .font(.system(size: 10, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.4))
                .lineLimit(1)
        }
    }

    private var progressBar: some View {
        TimelineView(.periodic(from: .now, by: track.isPlaying ? 0.5 : 3600)) { timeline in
            let elapsed = track.elapsed(at: timeline.date)
            let progress = track.progress(at: timeline.date)

            VStack(spacing: 2.5) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.16))
                            .frame(height: 3)

                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.95),
                                        Color.white.opacity(0.80)
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(3, geo.size.width * CGFloat(progress)), height: 3)
                    }
                    .frame(maxHeight: .infinity, alignment: .center)
                }
                .frame(height: 4)

                HStack {
                    Text(track.hasTrack ? elapsed.clockString : "0:00")
                        .font(.system(size: 8.5, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.55))

                    Spacer()

                    Text(track.duration > 0 ? track.duration.clockString : "--:--")
                        .font(.system(size: 8.5, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.55))
                }
            }
        }
        .frame(height: 13)
    }

    private var transport: some View {
        HStack(spacing: 18) {
            button("backward.fill", size: 11) { send(.previousTrack) }
            button(track.isPlaying ? "pause.fill" : "play.fill", size: 15) { send(.togglePlayPause) }
            button("forward.fill", size: 11) { send(.nextTrack) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func button(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(ScaleButtonStyle())
    }
}
