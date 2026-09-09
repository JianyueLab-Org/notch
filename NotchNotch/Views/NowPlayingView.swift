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
        HStack(spacing: 12) {
            artwork
            VStack(alignment: .leading, spacing: 2) {
                if !track.hasTrack, case .needsPermission(let message) = authorization {
                    permissionView(message: message)
                } else {
                    titles
                    Spacer(minLength: 6)
                    transport
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(white: 0.11))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
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
        .compositingGroup()
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
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.09), Color.white.opacity(0.03)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                        )

                    Image(systemName: !track.hasTrack && authorization.isBlocked ? "lock.shield.fill" : "music.note")
                        .font(.system(size: 28, weight: .medium))
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
        .frame(width: 82, height: 82)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
    }

    private func permissionView(message: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
                Text("Permission Needed")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            Text(message.contains("Music") ? "Allow Music in Automation" : "Allow Spotify in Automation")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(1)
            Spacer(minLength: 4)
            HStack(spacing: 6) {
                if let onRequestAuthorization {
                    Button {
                        onRequestAuthorization()
                    } label: {
                        Text("Grant")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
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
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 8))
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(Color.white.opacity(0.16))
                    )
                }
                .buttonStyle(.plain)
            }
        }
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
        HStack(spacing: 22) {
            button("backward.fill", size: 12.5) { send(.previousTrack) }
            button(track.isPlaying ? "pause.fill" : "play.fill", size: 17) { send(.togglePlayPause) }
            button("forward.fill", size: 12.5) { send(.nextTrack) }
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
        .buttonStyle(ScaleButtonStyle())
    }
}
