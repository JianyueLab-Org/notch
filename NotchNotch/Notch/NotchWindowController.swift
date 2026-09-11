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
    /// MediaRemote is primary (instant, rich metadata & artwork across all macOS audio players without permissions).
    /// AppleScript scripting sources (Spotify, Music) and Accessibility act as fallbacks.
    private let nowPlaying = NowPlayingController(source: CompositeNowPlayingSource(children: [
        MediaRemoteNowPlayingSource(),
        SpotifyScriptingSource(),
        MusicScriptingSource(),
        AccessibilityNowPlayingSource(),
    ]))
    private let shelf = ShelfController()
    private let schedule = ScheduleController.shared
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
        stateMachine = NotchStateMachine(layout: NotchLayout(geometry: detected, hasLiveActivity: false))
    }

    // MARK: - Lifecycle

    func start() {
        nowPlaying.start()
        WeatherController.shared.start()
        buildWindowIfNeeded()
        observeState()
        observeLiveActivities()
        observeScreenChanges()

        lastPointer = NSEvent.mouseLocation
        let monitor = NotchHoverMonitor { [weak self] location, _ in
            guard let self else { return }
            self.lastPointer = location
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
        let isMusicPlaying = (nowPlaying.nowPlaying?.isPlaying == true) && (nowPlaying.nowPlaying?.hasTrack == true)
        let hasLive = isMusicPlaying || schedule.hasActiveEvent
        let layout = NotchLayout(geometry: detected, hasLiveActivity: hasLive)
        stateMachine.collapseImmediately()
        stateMachine.layout = layout
        window?.setFrame(layout.windowFrame, display: true)
        Log.lifecycle.notice("controller: reloaded onto \(detected.screenName, privacy: .public)")
    }

    private func observeLiveActivities() {
        let weatherPublisher = Publishers.CombineLatest3(
            WeatherController.shared.$currentSnapshot,
            WeatherController.shared.$isEnabled,
            WeatherController.shared.$showInEars
        ).map { snapshot, isEnabled, showInEars in
            isEnabled && showInEars && (snapshot != nil)
        }

        Publishers.CombineLatest4(
            nowPlaying.$nowPlaying,
            schedule.$hasActiveEvent,
            AgentHarnessController.shared.$activeSession,
            weatherPublisher
        )
        .receive(on: DispatchQueue.main)
        .map { track, hasActiveSchedule, agent, isWeatherActive in
            let isMusicPlaying = (track?.isPlaying == true) && (track?.hasTrack == true)
            let isAgentActive = (agent?.state == .working || agent?.state.isWaiting == true)
            return isMusicPlaying || hasActiveSchedule || isAgentActive || isWeatherActive
        }
        .removeDuplicates()
        .sink { [weak self] hasLive in
            guard let self else { return }
            self.stateMachine.updateHasLiveActivity(hasLive)
        }
        .store(in: &cancellables)

        SystemMediaHUDController.shared.$isShowing
            .receive(on: DispatchQueue.main)
            .filter { $0 }
            .sink { [weak self] _ in
                self?.window?.orderFrontRegardless()
            }
            .store(in: &cancellables)

        AgentHarnessController.shared.$isShowingAlert
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isShowing in
                guard let self else { return }
                if isShowing {
                    self.window?.orderFrontRegardless()
                    self.window?.setInteractive(true)
                } else if self.stateMachine.state == .collapsed {
                    self.window?.setInteractive(false)
                }
            }
            .store(in: &cancellables)

        schedule.$isShowingAlert
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isShowing in
                guard let self else { return }
                if isShowing {
                    self.window?.orderFrontRegardless()
                    self.window?.setInteractive(true)
                } else if self.stateMachine.state == .collapsed {
                    self.window?.setInteractive(false)
                }
            }
            .store(in: &cancellables)
    }

    /// Toggles between expanded and collapsed states.
    func toggle() {
        if stateMachine.state.isOnScreen {
            stateMachine.collapseImmediately()
        } else {
            stateMachine.expandImmediately()
        }
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
            schedule: schedule
        )
        let hosting = NotchHostingView(rootView: panelView)
        hosting.onFileDragEntered = { [weak self] in
            guard let self else { return }
            self.window?.setInteractive(true)
            self.stateMachine.expandImmediately()
        }
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
                self.hoverMonitor?.setPollingEnabled(state == .collapsed)
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

        NotificationCenter.default
            .publisher(for: Notification.Name("co.jianyuelab.NotchNotch.expand"))
            .sink { [weak self] _ in
                self?.window?.setInteractive(true)
                self?.stateMachine.expandImmediately()
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: Notification.Name("co.jianyuelab.NotchNotch.selectTab"))
            .sink { [weak self] _ in
                self?.window?.setInteractive(true)
                self?.stateMachine.expandImmediately()
            }
            .store(in: &cancellables)

        DistributedNotificationCenter.default()
            .addObserver(forName: Notification.Name("co.jianyuelab.NotchNotch.expand"), object: nil, queue: .main) { [weak self] _ in
                self?.window?.setInteractive(true)
                self?.stateMachine.expandImmediately()
            }

        DistributedNotificationCenter.default()
            .addObserver(forName: Notification.Name("co.jianyuelab.NotchNotch.selectTab"), object: nil, queue: .main) { [weak self] notif in
                self?.window?.setInteractive(true)
                self?.stateMachine.expandImmediately()
                let tab = (notif.object as? String) ?? (notif.userInfo?["tab"] as? String)
                NotificationCenter.default.post(name: Notification.Name("co.jianyuelab.NotchNotch.selectTab"), object: tab)
            }
    }
}

// MARK: - Drag Detecting Hosting View

final class NotchHostingView<Content: View>: NSHostingView<Content> {
    var onFileDragEntered: (() -> Void)?
    var onFileDragExited: (() -> Void)?

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let pboard = sender.draggingPasteboard
        if pboard.canReadObject(forClasses: [NSURL.self], options: nil) {
            onFileDragEntered?()
            NotificationCenter.default.post(name: .notchFileDragEntered, object: nil)
            return .copy
        }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let pboard = sender.draggingPasteboard
        if pboard.canReadObject(forClasses: [NSURL.self], options: nil) {
            return .copy
        }
        return super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        super.draggingExited(sender)
        onFileDragExited?()
        NotificationCenter.default.post(name: .notchFileDragExited, object: nil)
    }
}

