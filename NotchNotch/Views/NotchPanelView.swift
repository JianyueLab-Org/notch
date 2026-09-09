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
        .onReceive(machine.$state) { state in
            if state == .collapsed {
                showSettings = false
                activeTab = .overview
            }
        }
    }

    private var notchShape: NotchShape {
        NotchShape(
            topRadius: isOpen ? NotchConfiguration.expandedTopCornerRadius : NotchConfiguration.collapsedTopCornerRadius,
            bottomRadius: isOpen ? NotchConfiguration.expandedBottomCornerRadius : NotchConfiguration.collapsedBottomCornerRadius
        )
    }

    private var panel: some View {
        ZStack(alignment: .top) {
            notchShape
                .fill(Color.black)

            compactContent
                .opacity(isOpen ? 0 : 1)
                .animation(.easeOut(duration: 0.12), value: isOpen)
                .allowsHitTesting(!isOpen)

            expandedContent
                .opacity(isOpen ? 1 : 0)
                .scaleEffect(isOpen ? 1.0 : 0.95, anchor: .top)
                .animation(.spring(response: 0.28, dampingFraction: 0.84), value: isOpen)
                .allowsHitTesting(isOpen)
        }
        .frame(width: bodySize.width, height: bodySize.height)
        .clipShape(notchShape)
        .shadow(color: .black.opacity(isOpen ? 0.45 : 0.25), radius: isOpen ? 14 : 4, y: isOpen ? 6 : 2)
    }

    // MARK: - Compact Content (Collapsed State)

    private var compactContent: some View {
        let notchWidth = machine.layout.geometry.notchRect.width
        let earWidth = max(28, (machine.layout.collapsedSize.width - notchWidth) / 2)

        return HStack(spacing: 0) {
            // Left ear: Calendar icon in rounded container
            ZStack {
                RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                    .fill(Color(red: 0.22, green: 0.12, blue: 0.04))
                    .frame(width: 22, height: 22)
                Image(systemName: "calendar")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(Color(red: 1.0, green: 0.58, blue: 0.12))
            }
            .frame(width: earWidth)

            // Center: Clear notch hardware area
            Spacer()
                .frame(width: notchWidth)

            // Right ear: Circular schedule progress ring
            ZStack {
                Circle()
                    .stroke(Color(red: 0.22, green: 0.12, blue: 0.04), lineWidth: 3.2)
                    .frame(width: 20, height: 20)
                Circle()
                    .trim(from: 0, to: max(0.04, min(1.0, schedule.progress)))
                    .stroke(Color(red: 1.0, green: 0.58, blue: 0.12), style: StrokeStyle(lineWidth: 3.2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 20, height: 20)
            }
            .frame(width: earWidth)
        }
        .frame(width: machine.layout.collapsedSize.width,
               height: machine.layout.collapsedSize.height)
        .clipped()
    }

    @ViewBuilder
    private var expandedContent: some View {
        VStack(spacing: 10) {
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
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 16)
        .frame(width: machine.layout.expandedSize.width,
               height: machine.layout.expandedSize.height)
        .foregroundStyle(.white)
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
                        .fill(showSettings ? Color.white.opacity(0.28) : Color.white.opacity(0.14))
                        .frame(width: 32, height: 32)
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(ScaleButtonStyle())
        }
        .frame(height: 34)
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
                            ? (isBlueActive ? Color(red: 0.05, green: 0.52, blue: 1.0) : Color.white.opacity(0.25))
                            : Color.white.opacity(0.14)
                    )
                    .frame(width: 32, height: 32)

                Image(systemName: icon)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.8))
                    .frame(width: 32, height: 32)

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
        .buttonStyle(ScaleButtonStyle())
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
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Responsive Tactile Feedback

struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.90 : 1.0)
            .opacity(configuration.isPressed ? 0.75 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
