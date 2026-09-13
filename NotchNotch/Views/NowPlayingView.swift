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
    @ObservedObject private var loc = LocalizationManager.shared

    var body: some View {
        HStack(spacing: 9) {
            artwork
            VStack(alignment: .leading, spacing: 3.5) {
                if !track.hasTrack, case .needsPermission(let message) = authorization {
                    permissionView(message: message)
                } else {
                    titles
                    progressBar
                    transport
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .jylCard()
    }

    // MARK: - Components

    private var artwork: some View {
        Group {
            if let image = track.artwork {
                 Image(nsImage: image)
                     .resizable()
                     .aspectRatio(contentMode: .fill)
                     .frame(width: 60, height: 60)
                     .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                     .overlay(
                         RoundedRectangle(cornerRadius: 10, style: .continuous)
                             .strokeBorder(JYLTheme.borderStrong, lineWidth: 0.5)
                     )
             } else {
                 ZStack {
                     RoundedRectangle(cornerRadius: 10, style: .continuous)
                         .fill(
                             LinearGradient(
                                 colors: [JYLTheme.neutral800, JYLTheme.neutral900],
                                 startPoint: .topLeading,
                                 endPoint: .bottomTrailing
                             )
                         )
                         .overlay(
                             RoundedRectangle(cornerRadius: 10, style: .continuous)
                                 .strokeBorder(JYLTheme.border, lineWidth: 0.5)
                         )

                     Image(systemName: !track.hasTrack && authorization.isBlocked ? "lock.shield.fill" : "music.note")
                         .font(.system(size: 21, weight: .medium))
                         .foregroundStyle(
                             LinearGradient(
                                 colors: !track.hasTrack && authorization.isBlocked
                                     ? [JYLTheme.warning, JYLTheme.warning.opacity(0.6)]
                                     : [JYLTheme.textSecondary, JYLTheme.textMuted],
                                 startPoint: .top,
                                 endPoint: .bottom
                             )
                         )
                 }
             }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 4, y: 1.5)
    }

    private func permissionView(message: String) -> some View {
        VStack(alignment: .leading, spacing: 2.5) {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(JYLTheme.warning)
                Text("Permission Needed")
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .foregroundStyle(JYLTheme.textPrimary)
            }
            Text(message.contains("Music") ? "Allow Music in Automation" : "Allow Spotify in Automation")
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundStyle(JYLTheme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 2)
            HStack(spacing: 6) {
                if let onRequestAuthorization {
                    Button {
                        onRequestAuthorization()
                    } label: {
                        Text("Grant")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(JYLTheme.textPrimary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(
                                Capsule().fill(JYLTheme.primary)
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
                    .foregroundStyle(JYLTheme.textSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(
                        Capsule().fill(JYLTheme.neutral800)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 1.5) {
            Text(track.title.isEmpty ? L10n.tr(.mediaNotPlaying) : track.title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(JYLTheme.textPrimary)
                .lineLimit(1)
            Text(track.artist.isEmpty ? "Music / Spotify" : track.artist)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(JYLTheme.textSecondary)
                .lineLimit(1)
            Text(track.album.isEmpty ? (track.title.isEmpty ? "Ready to play" : track.artist) : track.album)
                .font(.system(size: 9.5, weight: .regular, design: .rounded))
                .foregroundStyle(JYLTheme.textMuted)
                .lineLimit(1)
        }
    }

    private var progressBar: some View {
        TimelineView(.periodic(from: .now, by: track.isPlaying ? 0.5 : 3600)) { timeline in
            let elapsed = track.elapsed(at: timeline.date)
            let progress = track.progress(at: timeline.date)

            VStack(spacing: 2) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(JYLTheme.neutral800)
                            .frame(height: 3)

                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        JYLTheme.primary,
                                        JYLTheme.primaryLight
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(3, geo.size.width * CGFloat(progress)), height: 3)
                    }
                    .frame(maxHeight: .infinity, alignment: .center)
                }
                .frame(height: 3)

                HStack {
                    Text(track.hasTrack ? elapsed.clockString : "0:00")
                        .font(.system(size: 8.5, weight: .medium, design: .rounded))
                        .foregroundStyle(JYLTheme.textMuted)

                    Spacer()

                    Text(track.duration > 0 ? track.duration.clockString : "--:--")
                        .font(.system(size: 8.5, weight: .medium, design: .rounded))
                        .foregroundStyle(JYLTheme.textMuted)
                }
            }
        }
        .frame(height: 12)
    }

    private var transport: some View {
        HStack(spacing: 14) {
            button("backward.fill", size: 10.5) { send(.previousTrack) }
            button(track.isPlaying ? "pause.fill" : "play.fill", size: 13.5) { send(.togglePlayPause) }
            button("forward.fill", size: 10.5) { send(.nextTrack) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func button(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(JYLTheme.textPrimary)
                .frame(width: 22, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(ScaleButtonStyle())
    }
}
