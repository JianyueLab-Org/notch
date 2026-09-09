//
//  NotchPanelView.swift
//  NotchNotch
//
//  The visual shell with top circular navigation buttons and dual-card layout.
//

import SwiftUI

enum NotchActiveTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case shelf = "Drop Shelf"
    case clipboard = "Clipboard"
    var id: String { rawValue }
}

struct NotchPanelView: View {

    @ObservedObject var machine: NotchStateMachine
    @ObservedObject var media: NowPlayingController
    @ObservedObject var shelf: ShelfController
    @ObservedObject var schedule: ScheduleController
    @Binding var activeTab: NotchActiveTab
    @State private var showSettings: Bool = false

    private var isOpen: Bool { machine.state.isVisiblyExpanded }

    private var bodySize: CGSize {
        isOpen ? machine.layout.expandedSize : machine.layout.collapsedSize
    }

    var body: some View {
        VStack(spacing: 0) {
            panel
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var panel: some View {
        NotchShape(topRadius: isOpen ? NotchConfiguration.expandedTopCornerRadius
                                     : NotchConfiguration.collapsedTopCornerRadius,
                   bottomRadius: isOpen ? NotchConfiguration.expandedBottomCornerRadius
                                        : NotchConfiguration.collapsedBottomCornerRadius)
            .fill(Color.black)
            .overlay(alignment: .top) {
                if machine.state.isOnScreen { expandedContent }
            }
            .frame(width: bodySize.width, height: bodySize.height)
            .shadow(color: .black.opacity(isOpen ? 0.45 : 0), radius: 14, y: 6)
    }

    @ViewBuilder
    private var expandedContent: some View {
        VStack(spacing: 8) {
            topBar

            Group {
                if showSettings {
                    settingsContent
                } else {
                    switch activeTab {
                    case .overview:
                        overviewContent
                    case .shelf:
                        DropShelfView(shelf: shelf)
                    case .clipboard:
                        ClipboardCardView()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 12)
        .frame(width: machine.layout.expandedSize.width,
               height: machine.layout.expandedSize.height)
        .foregroundStyle(.white)
        .opacity(isOpen ? 1 : 0)
        .allowsHitTesting(isOpen)
        .clipped()
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(alignment: .center) {
            // Left circular icon buttons
            HStack(spacing: 8) {
                circleIconButton(
                    tab: .overview,
                    icon: "square.grid.2x2.fill",
                    isBlueActive: true
                )
                circleIconButton(
                    tab: .shelf,
                    icon: "folder.fill",
                    isBlueActive: false,
                    badge: shelf.items.isEmpty ? nil : "\(shelf.items.count)"
                )
                circleIconButton(
                    tab: .clipboard,
                    icon: "doc.on.doc.fill",
                    isBlueActive: false
                )
            }

            Spacer()

            // Right settings gear button
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                    showSettings.toggle()
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(showSettings ? Color.white.opacity(0.28) : Color.white.opacity(0.12))
                        .frame(width: 34, height: 34)
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
        }
        .frame(height: 36)
    }

    private func circleIconButton(
        tab: NotchActiveTab,
        icon: String,
        isBlueActive: Bool = false,
        badge: String? = nil
    ) -> some View {
        let isSelected = activeTab == tab && !showSettings
        return Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                showSettings = false
                activeTab = tab
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                Circle()
                    .fill(
                        isSelected
                            ? (isBlueActive ? Color(red: 0.0, green: 0.52, blue: 1.0) : Color.white.opacity(0.25))
                            : Color.white.opacity(0.12)
                    )
                    .frame(width: 34, height: 34)

                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.75))
                    .frame(width: 34, height: 34)

                if let badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor))
                        .offset(x: 4, y: -2)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Overview Content

    private var overviewContent: some View {
        HStack(spacing: 12) {
            // Left: Media Card
            let track = media.nowPlaying ?? NowPlaying(
                title: "", artist: "", album: "", isPlaying: false,
                duration: 0, reportedElapsed: 0, reportedAt: .now, playbackRate: 0
            )
            NowPlayingView(track: track) { media.send($0) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Right: Schedule Timeline Card
            ScheduleTimelineCardView(schedule: schedule)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Settings View

    private var settingsContent: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("NotchNotch Quick Settings")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text("Custom status panel for Apple Silicon notch")
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))

                Spacer()
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )

            VStack(spacing: 8) {
                Button("Re-detect Notch Display") {
                    // Triggers screen re-detect via notification
                    NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.12)))

                Button("Close Settings") {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                        showSettings = false
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
