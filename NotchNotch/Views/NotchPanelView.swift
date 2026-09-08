//
//  NotchPanelView.swift
//  NotchNotch
//
//  The visual shell with segmented navigation between Now Playing and Drop Shelf.
//

import SwiftUI

enum NotchActiveTab: String, CaseIterable, Identifiable {
    case nowPlaying = "Now Playing"
    case shelf = "Drop Shelf"
    var id: String { rawValue }
}

struct NotchPanelView: View {

    @ObservedObject var machine: NotchStateMachine
    @ObservedObject var media: NowPlayingController
    @ObservedObject var shelf: ShelfController
    @Binding var activeTab: NotchActiveTab

    private var isOpen: Bool { machine.state.isVisiblyExpanded }

    private var bodySize: CGSize {
        isOpen ? machine.layout.expandedSize : machine.layout.collapsedSize
    }

    var body: some View {
        // Top-anchored: the panel hangs from the screen edge. The Spacer soaks
        // up the rest of the window, and — unlike a Color — is not hit-testable,
        // so the empty area below the panel stays click-through even while the
        // window itself is accepting events.
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
                // Built only while the panel is on screen. Keeping it around at
                // opacity 0 would leave NowPlayingView's TimelineView ticking
                // forever for a panel nobody can see.
                if machine.state.isOnScreen { expandedContent }
            }
            .frame(width: bodySize.width, height: bodySize.height)
            .shadow(color: .black.opacity(isOpen ? 0.45 : 0), radius: 14, y: 6)
    }

    @ViewBuilder
    private var expandedContent: some View {
        VStack(spacing: 8) {
            tabHeader

            Group {
                switch activeTab {
                case .nowPlaying:
                    mediaContent
                case .shelf:
                    DropShelfView(shelf: shelf)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
        }
        .padding(.horizontal, 16)
        .padding(.top, machine.layout.geometry.notchRect.height + 4)
        .padding(.bottom, 12)
        .frame(width: machine.layout.expandedSize.width,
               height: machine.layout.expandedSize.height)
        .foregroundStyle(.white)
        // Fading with the same spring keeps the text from appearing to pop in
        // late; clipping stops it spilling out while the body is still small.
        .opacity(isOpen ? 1 : 0)
        .allowsHitTesting(isOpen)
        .clipped()
    }

    private var tabHeader: some View {
        HStack(spacing: 4) {
            tabButton(tab: .nowPlaying, systemImage: "music.note", title: "Playing", badge: nil)
            tabButton(tab: .shelf, systemImage: "tray.full", title: "Shelf", badge: shelf.items.isEmpty ? nil : "\(shelf.items.count)")
        }
        .padding(3)
        .background(Capsule().fill(Color.white.opacity(0.10)))
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func tabButton(tab: NotchActiveTab, systemImage: String, title: String, badge: String?) -> some View {
        let isSelected = activeTab == tab
        return Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                activeTab = tab
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                if let badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(isSelected ? Color.white.opacity(0.25) : Color.accentColor))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(isSelected ? Color.white.opacity(0.18) : Color.clear)
            )
            .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.55))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var mediaContent: some View {
        if let track = media.nowPlaying, track.hasTrack {
            NowPlayingView(track: track) { media.send($0) }
        } else {
            emptyMediaState
        }
    }

    @ViewBuilder
    private var emptyMediaState: some View {
        VStack(spacing: 8) {
            if case .needsPermission(let reason) = media.authorization {
                Image(systemName: "lock.shield")
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.35))
                Text(reason)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Grant Access…") { media.requestAuthorization() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Capsule().fill(.white.opacity(0.16)))
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.3))
                Text("Nothing playing")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
