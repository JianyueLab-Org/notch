//
//  NotchStateMachine.swift
//  NotchNotch
//
//  The one place that decides whether the panel is open. Everything else —
//  the window, the event monitors, the views — either feeds this or reacts to
//  it. Keeping it a four-state machine rather than an `isExpanded` Bool matters
//  because "opening" and "closing" are real states with their own rules: a
//  cursor re-entry during `collapsing` has to cancel the close, and the window
//  must keep accepting mouse events until the close has actually finished.
//

import Combine
import OSLog
import SwiftUI

nonisolated enum NotchState: String, Equatable, Sendable, CaseIterable {
    case collapsed
    case expanding
    case expanded
    case collapsing

    /// The panel body should be drawn at its expanded size in these states.
    var isVisiblyExpanded: Bool {
        self == .expanding || self == .expanded
    }

    /// Whether the panel is on screen at all — collapsing still counts, because
    /// the body is visibly shrinking rather than already gone.
    ///
    /// NOTE: this is *not* the click-through rule. Whether the window accepts a
    /// click also depends on where the cursor is; see
    /// `NotchLayout.acceptsClick(at:in:)`.
    var isOnScreen: Bool {
        self != .collapsed
    }

    /// Once expanded, hysteresis switches hit-testing from the small notch
    /// rect to the large panel rect.
    var usesExpandedHitRegion: Bool {
        self != .collapsed
    }
}

@MainActor
final class NotchStateMachine: ObservableObject {

    @Published private(set) var state: NotchState = .collapsed

    /// Injected by `NotchWindowController` whenever the display configuration
    /// changes. The state machine needs it for hit testing; the views need it
    /// for sizing; one source of truth beats two.
    @Published var layout: NotchLayout

    /// Fires the settle transition (expanding → expanded, collapsing → collapsed).
    private var settleTask: Task<Void, Never>?
    /// Debounce before a close actually starts.
    private var collapseDelayTask: Task<Void, Never>?
    /// Dwell confirmation before an expand actually starts.
    private var expandDwellTask: Task<Void, Never>?

    init(layout: NotchLayout) {
        self.layout = layout
    }

    // MARK: - Input

    /// Feed every cursor position here. Cheap enough to call at event rate.
    func pointerMoved(to location: CGPoint) {
        let region = state.usesExpandedHitRegion ? layout.exitRegion : layout.enterRegion
        if region.contains(location) {
            pointerIsInside()
        } else {
            pointerIsOutside()
        }
    }

    /// Force the panel shut — display reconfiguration, app shutdown, etc.
    func collapseImmediately() {
        cancelPendingWork()
        guard state != .collapsed else { return }
        Log.state.notice("state: \(self.state.rawValue, privacy: .public) -> collapsed (forced)")
        withAnimation(NotchConfiguration.collapseAnimation) {
            state = .collapsed
        }
    }

    /// Force the panel open — menu bar toggle, hotkey, etc.
    func expandImmediately() {
        cancelPendingWork()
        guard state != .expanded else { return }
        print("[NotchNotch] ⚡️ Forced expand! (\(state.rawValue) -> expanded)")
        Log.state.notice("state: \(self.state.rawValue, privacy: .public) -> expanded (forced)")
        withAnimation(NotchConfiguration.expandAnimation) {
            state = .expanded
        }
    }

    // MARK: - Transitions

    private func pointerIsInside() {
        // Any re-entry cancels a pending close, whether it is still in the
        // debounce window or already animating shut.
        if collapseDelayTask != nil {
            collapseDelayTask?.cancel()
            collapseDelayTask = nil
        }

        switch state {
        case .collapsed, .collapsing:
            guard expandDwellTask == nil else { return }
            expandDwellTask = Task { [weak self] in
                try? await Task.sleep(for: NotchConfiguration.hoverExpandDwellDelay)
                guard !Task.isCancelled, let self else { return }
                self.expandDwellTask = nil
                print("[NotchNotch] 🎯 Pointer dwelled in notch region! Expanding... (\(self.state.rawValue) -> expanding)")
                fflush(stdout)
                self.transition(to: .expanding, animation: NotchConfiguration.expandAnimation)
                self.settle(to: .expanded, after: NotchConfiguration.expandSettleDuration)
            }
        case .expanding, .expanded:
            if expandDwellTask != nil {
                expandDwellTask?.cancel()
                expandDwellTask = nil
            }
        }
    }

    private func pointerIsOutside() {
        if expandDwellTask != nil {
            expandDwellTask?.cancel()
            expandDwellTask = nil
        }

        switch state {
        case .collapsed, .collapsing:
            break
        case .expanding, .expanded:
            // Debounce. A single stray event on the boundary should not close a
            // panel the user is still reaching for.
            guard collapseDelayTask == nil else { return }
            collapseDelayTask = Task { [weak self] in
                try? await Task.sleep(for: NotchConfiguration.collapseDelay)
                guard !Task.isCancelled, let self else { return }
                self.collapseDelayTask = nil
                self.beginCollapse()
            }
        }
    }

    private func beginCollapse() {
        guard state.isVisiblyExpanded else { return }
        print("[NotchNotch] 💨 Pointer left notch region. Collapsing... (\(state.rawValue) -> collapsing)")
        fflush(stdout)
        transition(to: .collapsing, animation: NotchConfiguration.collapseAnimation)
        settle(to: .collapsed, after: NotchConfiguration.collapseSettleDuration)
    }

    private func transition(to next: NotchState, animation: Animation) {
        guard state != next else { return }
        Log.state.notice("state: \(self.state.rawValue, privacy: .public) -> \(next.rawValue, privacy: .public)")
        // GOTCHA: the mutation has to happen *inside* withAnimation, on the same
        // synchronous turn as the event that caused it. Setting the state first
        // and animating afterwards gives you a jump cut.
        withAnimation(animation) {
            state = next
        }
    }

    /// Springs have no real duration, so the transient states are ended by a
    /// timer rather than an animation-completion callback (which would need
    /// macOS 14's `withAnimation(_:completionCriteria:completion:)`).
    private func settle(to next: NotchState, after duration: Duration) {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self else { return }
            self.settleTask = nil
            switch (self.state, next) {
            case (.expanding, .expanded), (.collapsing, .collapsed):
                Log.state.notice("state: \(self.state.rawValue, privacy: .public) -> \(next.rawValue, privacy: .public) (settled)")
                self.state = next
            default:
                break // the machine moved on while we were asleep
            }
        }
    }

    private func cancelPendingWork() {
        settleTask?.cancel()
        settleTask = nil
        collapseDelayTask?.cancel()
        collapseDelayTask = nil
        expandDwellTask?.cancel()
        expandDwellTask = nil
    }

    deinit {
        settleTask?.cancel()
        collapseDelayTask?.cancel()
        expandDwellTask?.cancel()
    }
}
