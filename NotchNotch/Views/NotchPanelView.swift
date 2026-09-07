//
//  NotchPanelView.swift
//  NotchNotch
//
//  The whole visual shell. Everything is a function of `machine.state` and
//  `machine.layout`; there is no local animation state, so there is exactly one
//  thing that can be out of sync and it lives in the state machine.
//
//  NOTE ON macOS 13: this uses ObservableObject / @ObservedObject rather than
//  @Observable, because the Observation framework is macOS 14+. Swap them when
//  the deployment target rises.
//

import SwiftUI

struct NotchPanelView: View {

    @ObservedObject var machine: NotchStateMachine
    @ObservedObject var media: NowPlayingController

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
            // Shadow only once open — while collapsed the body is meant to be
            // indistinguishable from the physical notch, and a shadow would
            // give it away as a rectangle sitting on the bezel.
            .shadow(color: .black.opacity(isOpen ? 0.45 : 0), radius: 14, y: 6)
    }

    @ViewBuilder
    private var content: some View {
        if let track = media.nowPlaying, track.hasTrack {
            NowPlayingView(track: track) { media.send($0) }
        } else {
            emptyState
        }
    }

    @ViewBuilder
    private var emptyState: some View {
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

    @ViewBuilder
    private var expandedContent: some View {
        VStack(spacing: 10) {

            content
        }
        .padding(.horizontal, 18)
        .padding(.top, machine.layout.geometry.notchRect.height + 6)
        .padding(.bottom, 16)
        .frame(width: machine.layout.expandedSize.width,
               height: machine.layout.expandedSize.height)
        .foregroundStyle(.white)
        // Fading with the same spring keeps the text from appearing to pop in
        // late; clipping stops it spilling out while the body is still small.
        .opacity(isOpen ? 1 : 0)
        .allowsHitTesting(isOpen)
        .clipped()
    }
}
