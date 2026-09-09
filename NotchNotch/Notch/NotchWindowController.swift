//
//  NotchWindowController.swift
//  NotchNotch
//
//  Wiring. Owns the window, the state machine and the hover monitor, and keeps
//  the three in sync. Deliberately the only file that knows about all three, so
//  each of them stays independently testable.
//

import AppKit
import OSLog
import Combine
import SwiftUI

@MainActor
final class NotchWindowController {

    private var window: NotchOverlayWindow?
    private var hoverMonitor: NotchHoverMonitor?
    private var cancellables: Set<AnyCancellable> = []

    private let stateMachine: NotchStateMachine

    /// The one place that picks backends, in priority order.
    ///
    /// `MediaRemoteNowPlayingSource` is deliberately absent: it is the richest
    /// option but was verified to return an empty dictionary for anything not
    /// signed by Apple on macOS 27. It stays in the tree for the day this app
    /// has the entitlement to use it.
    private let nowPlaying = NowPlayingController(source: CompositeNowPlayingSource(children: [
        SpotifyScriptingSource(),
        MusicScriptingSource(),
        AccessibilityNowPlayingSource(),
    ]))
    private let shelf = ShelfController()
    private let schedule = ScheduleController()
    @Published var activeTab: NotchActiveTab = .overview
    private(set) var geometry: NotchGeometry

    /// Last cursor position we were told about. `ignoresMouseEvents` is a
    /// function of (state, cursor), so we need to remember the cursor to
    /// recompute it when the state changes without the mouse moving.
    private var lastPointer: CGPoint = .zero

    init() {
        let screen = NotchGeometry.preferredScreen()
        let detected = screen.map { NotchGeometry.detect(on: $0) }
            ?? NotchGeometry(notchRect: .zero, screenFrame: .zero, source: .simulated, screenName: "none")
        geometry = detected
        stateMachine = NotchStateMachine(layout: NotchLayout(geometry: detected))
    }

    // MARK: - Lifecycle

    func start() {
        nowPlaying.start()
        buildWindowIfNeeded()
        observeState()
        observeScreenChanges()

        lastPointer = NSEvent.mouseLocation
        let monitor = NotchHoverMonitor { [weak self] location, isDragging in
            guard let self else { return }
            self.lastPointer = location
            if isDragging && self.stateMachine.state == .collapsed && self.checkFileDrag() {
                self.activeTab = .shelf
            }
            self.stateMachine.pointerMoved(to: location)
            if self.stateMachine.state != .collapsed {
                self.updateInteractivity(for: self.stateMachine.state)
            }
        }
        monitor.start()
        hoverMonitor = monitor

        Log.lifecycle.notice("controller: started (\(self.geometry.source.rawValue, privacy: .public) notch on \(self.geometry.screenName, privacy: .public))")
        print("[NotchWindowController] Started with geometry: \(self.geometry.notchRect), screen: \(self.geometry.screenFrame)")
        fflush(stdout)
    }

    func stop() {
        nowPlaying.stop()
        hoverMonitor?.stop()
        hoverMonitor = nil
        cancellables.removeAll()
        stateMachine.collapseImmediately()
        window?.orderOut(nil)
        Log.lifecycle.notice("controller: stopped")
    }

    /// Re-detect the display and rebuild the layout. Exposed on the status menu
    /// because display reconfiguration is the one thing most likely to need a
    /// manual nudge while developing.
    func reload() {
        guard let screen = NotchGeometry.preferredScreen() else { return }
        let detected = NotchGeometry.detect(on: screen)
        geometry = detected
        let layout = NotchLayout(geometry: detected)
        stateMachine.collapseImmediately()
        stateMachine.layout = layout
        window?.setFrame(layout.windowFrame, display: true)
        Log.lifecycle.notice("controller: reloaded onto \(detected.screenName, privacy: .public)")
    }

    /// Toggles between expanded and collapsed states.
    func toggle() {
        if stateMachine.state.isOnScreen {
            stateMachine.collapseImmediately()
            activeTab = .overview
        } else {
            activeTab = .overview
            stateMachine.expandImmediately()
        }
    }

    private var lastDragCheckTime: TimeInterval = 0
    private var cachedIsFileDrag: Bool = false

    private func checkFileDrag() -> Bool {
        let now = CACurrentMediaTime()
        if now - lastDragCheckTime > 0.25 {
            lastDragCheckTime = now
            let types = NSPasteboard(name: .drag).types ?? []
            cachedIsFileDrag = types.contains(.fileURL) || types.contains(NSPasteboard.PasteboardType("NSFilenamesPboardType"))
        }
        return cachedIsFileDrag
    }

    // MARK: - Window

    private func buildWindowIfNeeded() {
        guard window == nil else { return }

        let layout = stateMachine.layout
        let window = NotchOverlayWindow(contentRect: layout.windowFrame)

        let panelView = NotchPanelView(
            machine: stateMachine,
            media: nowPlaying,
            shelf: shelf,
            schedule: schedule,
            activeTab: Binding(
                get: { [weak self] in self?.activeTab ?? .overview },
                set: { [weak self] in self?.activeTab = $0 }
            )
        )
        let hosting = NSHostingView(rootView: panelView)
        // The hosting view must not paint a background of its own, or the
        // "transparent window" is a grey rectangle.
        hosting.layer?.backgroundColor = .clear
        window.contentView = hosting

        window.setFrame(layout.windowFrame, display: false)

        // `orderFrontRegardless()` rather than `makeKeyAndOrderFront(_:)`: we
        // are an accessory app that is never "active", and the plain
        // `orderFront(_:)` is ignored for an inactive application.
        window.orderFrontRegardless()

        if NotchConfiguration.usesPrivateWindowElevation {
            PrivateWindowElevation.elevate(window)
        }

        self.window = window
    }

    // MARK: - Reacting to state

    private func observeState() {
        stateMachine.$state
            .removeDuplicates()
            .sink { [weak self] state in
                guard let self else { return }
                // GOTCHA: @Published emits in willSet, so `stateMachine.state`
                // is still the OLD value in here. Always use the `state`
                // argument, never re-read the property.
                self.updateInteractivity(for: state)
                self.hoverMonitor?.setPollingEnabled(state != .collapsed)
                if state == .collapsed {
                    self.activeTab = .overview
                }
            }
            .store(in: &cancellables)
    }

    /// The window must accept clicks only while the cursor is genuinely over the
    /// painted body — anywhere else in its (much larger) frame has to stay
    /// click-through, or the top of the screen goes dead whenever the panel is
    /// open. `NotchLayout.acceptsClick(at:in:)` documents why this cannot be
    /// solved with a `hitTest(_:)` override.
    private func updateInteractivity(for state: NotchState) {
        if state == .collapsed {
            window?.setInteractive(false)
        } else {
            window?.setInteractive(stateMachine.layout.acceptsClick(at: lastPointer, in: state))
        }
    }

    private func observeScreenChanges() {
        // Fires for resolution changes, display connect/disconnect, and also
        // when the menu bar auto-hide setting changes — all of which move the
        // notch rect out from under us.
        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                Log.geometry.notice("geometry: screen parameters changed, re-detecting")
                self?.reload()
            }
            .store(in: &cancellables)
    }
}
