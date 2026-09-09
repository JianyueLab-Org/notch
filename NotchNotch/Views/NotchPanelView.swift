//
//  NotchPanelView.swift
//  NotchNotch
//
//  The visual shell with top circular navigation buttons and dual-card layout.
//

import SwiftUI
import UniformTypeIdentifiers
import OSLog

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
    @State private var activeTab: NotchActiveTab = .overview
    @State private var showSettings: Bool = false
    @State private var isDraggingFile: Bool = false

    private var isOpen: Bool { machine.state.isVisiblyExpanded }

    private var collapsedWidth: CGFloat {
        let notchWidth = machine.layout.geometry.notchRect.width
        return hasLiveActivity ? notchWidth + NotchConfiguration.compactWidthExtension : notchWidth
    }

    private var bodySize: CGSize {
        isOpen ? machine.layout.expandedSize : CGSize(width: collapsedWidth, height: machine.layout.collapsedSize.height)
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
                isDraggingFile = false
                activeTab = .overview
            } else if state == .expanding {
                showSettings = false
                if !isDraggingFile {
                    activeTab = .overview
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .notchFileDragEntered)) { _ in
            isDraggingFile = true
            withAnimation(.easeInOut(duration: 0.12)) {
                activeTab = .shelf
            }
            if !machine.state.isVisiblyExpanded {
                machine.expandImmediately()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .notchFileDragExited)) { _ in
            isDraggingFile = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .notchFileDropped)) { notif in
            isDraggingFile = false
            if let urls = notif.object as? [URL], !urls.isEmpty {
                shelf.addURLs(urls)
                withAnimation(.easeInOut(duration: 0.12)) {
                    activeTab = .shelf
                }
            }
        }
        .onChange(of: isDraggingFile) { isDragging in
            if isDragging {
                withAnimation(.easeInOut(duration: 0.12)) {
                    activeTab = .shelf
                }
                if !machine.state.isVisiblyExpanded {
                    machine.expandImmediately()
                }
            }
        }
    }

    private var isMusicPlaying: Bool {
        (media.nowPlaying?.isPlaying == true) && (media.nowPlaying?.hasTrack == true)
    }

    private var hasLiveActivity: Bool {
        isMusicPlaying || schedule.hasActiveEvent
    }

    private var notchShape: NotchShape {
        let collapsedTop = hasLiveActivity ? NotchConfiguration.collapsedTopCornerRadius : 0
        let collapsedBottom = hasLiveActivity ? NotchConfiguration.collapsedBottomCornerRadius : 10
        return NotchShape(
            topRadius: isOpen ? NotchConfiguration.expandedTopCornerRadius : collapsedTop,
            bottomRadius: isOpen ? NotchConfiguration.expandedBottomCornerRadius : collapsedBottom
        )
    }

    private var panel: some View {
        ZStack(alignment: .top) {
            notchShape
                .fill(Color.black)

            compactContent
                .opacity(isOpen ? 0 : 1)
                .animation(isOpen ? .easeOut(duration: 0.08) : .easeIn(duration: 0.14).delay(0.08), value: isOpen)
                .allowsHitTesting(!isOpen)

            if machine.state.isOnScreen {
                expandedContent
                    .opacity(isOpen ? 1 : 0)
                    .scaleEffect(isOpen ? 1.0 : 0.96, anchor: .top)
                    .animation(isOpen ? NotchConfiguration.expandAnimation : .easeOut(duration: 0.12), value: isOpen)
                    .allowsHitTesting(isOpen)
            }
        }
        .frame(width: bodySize.width, height: bodySize.height, alignment: .top)
        .clipShape(notchShape)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: bodySize.width)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: hasLiveActivity)
        .compositingGroup()
        .shadow(
            color: .black.opacity(isOpen ? 0.45 : (hasLiveActivity ? 0.25 : 0)),
            radius: isOpen ? 14 : 4,
            y: isOpen ? 6 : 2
        )
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDraggingFile) { providers in
            isDraggingFile = true
            withAnimation(.easeInOut(duration: 0.12)) {
                activeTab = .shelf
            }
            return handleFileDrop(providers: providers)
        }
    }

    // MARK: - File Drop Support

    private func handleFileDrop(providers: [NSItemProvider]) -> Bool {
        var foundURLs: [URL] = []
        let group = DispatchGroup()

        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    foundURLs.append(url)
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            self.isDraggingFile = false
            if !foundURLs.isEmpty {
                self.shelf.addURLs(foundURLs)
                withAnimation(.easeInOut(duration: 0.12)) {
                    self.activeTab = .shelf
                }
            }
        }

        return true
    }

    // MARK: - Compact Content (Collapsed State)

    @ViewBuilder
    private var compactContent: some View {
        if hasLiveActivity {
            let notchWidth = machine.layout.geometry.notchRect.width
            let earWidth = NotchConfiguration.compactWidthExtension / 2

            HStack(spacing: 0) {
                // Left ear
                compactLeftEar
                    .frame(width: earWidth)

                // Center: Clear notch hardware area (fixed rigid cutout)
                Color.clear
                    .frame(width: notchWidth, height: machine.layout.collapsedSize.height)

                // Right ear
                compactRightEar
                    .frame(width: earWidth)
            }
            .frame(width: collapsedWidth,
                   height: machine.layout.collapsedSize.height)
        }
    }

    @ViewBuilder
    private var compactLeftEar: some View {
        if isMusicPlaying {
            if let artwork = media.nowPlaying?.artwork, artwork.isValid, artwork.size.width > 0 {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 21, height: 21)
                    .clipShape(RoundedRectangle(cornerRadius: 5.5, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                    )
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color(red: 0.95, green: 0.22, blue: 0.38), Color(red: 0.85, green: 0.15, blue: 0.45)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 21, height: 21)
                    Image(systemName: "music.note")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        } else if schedule.hasActiveEvent {
            ZStack {
                RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                    .fill(Color(red: 0.22, green: 0.12, blue: 0.04))
                    .frame(width: 22, height: 22)
                Image(systemName: "calendar")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(Color(red: 1.0, green: 0.58, blue: 0.12))
            }
        }
    }

    @ViewBuilder
    private var compactRightEar: some View {
        if isMusicPlaying, let track = media.nowPlaying {
            TimelineView(.periodic(from: .now, by: track.isPlaying ? 0.5 : 3600)) { timeline in
                let progress = track.progress(at: timeline.date)
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.18), lineWidth: 2.8)
                        .frame(width: 19, height: 19)
                    Circle()
                        .trim(from: 0, to: max(0.04, min(1.0, progress)))
                        .stroke(
                            LinearGradient(
                                colors: [Color(red: 0.22, green: 0.65, blue: 1.0), Color(red: 0.50, green: 0.85, blue: 1.0)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            style: StrokeStyle(lineWidth: 2.8, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .frame(width: 19, height: 19)
                }
            }
        } else if schedule.hasActiveEvent {
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
        }
    }

    @ViewBuilder
    private var expandedContent: some View {
        VStack(spacing: 10) {
            topBar

            ZStack {
                overviewContent
                    .opacity(activeTab == .overview && !showSettings ? 1 : 0)
                    .allowsHitTesting(activeTab == .overview && !showSettings)

                DropShelfView(shelf: shelf)
                    .opacity(activeTab == .shelf && !showSettings ? 1 : 0)
                    .allowsHitTesting(activeTab == .shelf && !showSettings)

                ClipboardCardView(isActive: activeTab == .clipboard && !showSettings)
                    .opacity(activeTab == .clipboard && !showSettings ? 1 : 0)
                    .allowsHitTesting(activeTab == .clipboard && !showSettings)

                settingsContent
                    .opacity(showSettings ? 1 : 0)
                    .allowsHitTesting(showSettings)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    icon: "tray.fill",
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
                withAnimation(.easeInOut(duration: 0.12)) {
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
            .buttonStyle(TabButtonStyle())
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
            withAnimation(.easeInOut(duration: 0.12)) {
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
        .buttonStyle(TabButtonStyle())
    }

    // MARK: - Overview Content

    private var overviewContent: some View {
        HStack(spacing: 12) {
            // Left: Media Card
            let track = media.nowPlaying ?? NowPlaying(
                title: "", artist: "", album: "", isPlaying: false,
                duration: 0, reportedElapsed: 0, reportedAt: .now, playbackRate: 0
            )
            NowPlayingView(
                track: track,
                authorization: media.authorization,
                onRequestAuthorization: { media.requestAuthorization() }
            ) { media.send($0) }
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
                    withAnimation(.easeInOut(duration: 0.12)) {
                        showSettings = false
                    }
                }
                .buttonStyle(TabButtonStyle())
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

// MARK: - Button Styles

struct TabButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1.0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.spring(response: 0.12, dampingFraction: 0.85), value: configuration.isPressed)
    }
}
