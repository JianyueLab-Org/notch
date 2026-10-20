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

private struct ActiveFileDrag {
    var urls: [URL]
    var inside: Bool
}

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

    /// `NSPasteboard.drag.changeCount` while no button is down. A file drag
    /// bumps it; a plain click does not, so a stale pasteboard cannot open the
    /// panel on the next mouse-down.
    private var idleDragChangeCount = NSPasteboard(name: .drag).changeCount
    private var latchedFileDrag: (changeCount: Int, urls: [URL])?
    private var activeFileDrag: ActiveFileDrag?
    private var lastFileDrag = false
    private var wasDragging = false

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
        let monitor = NotchHoverMonitor { [weak self] location, isDragging in
            self?.handlePointer(location, isDragging: isDragging)
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
        let isAgentActive = (AgentHarnessController.shared.activeSession?.state == .working || AgentHarnessController.shared.activeSession?.state.isWaiting == true)
        let isWeatherActive = WeatherController.shared.isEnabled && WeatherController.shared.showInEars && (WeatherController.shared.currentSnapshot != nil)
        let hasLive = isMusicPlaying || schedule.hasActiveEvent || isAgentActive || isWeatherActive
        let layout = NotchLayout(geometry: detected, hasLiveActivity: hasLive)
        stateMachine.collapseImmediately()
        stateMachine.layout = layout
        window?.setFrame(layout.windowFrame, display: true)
        updateInteractivity(for: .collapsed)
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
                }
                self.updateInteractivity(for: self.stateMachine.state)
            }
            .store(in: &cancellables)

        schedule.$isShowingAlert
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isShowing in
                guard let self else { return }
                if isShowing {
                    self.window?.orderFrontRegardless()
                }
                self.updateInteractivity(for: self.stateMachine.state)
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

    private var isAlertShowing: Bool {
        AgentHarnessController.shared.isShowingAlert || schedule.isShowingAlert
    }

    /// The window must accept clicks only while the cursor is genuinely over the
    /// painted body — anywhere else in its (much larger) frame has to stay
    /// click-through, or the top of the screen goes dead whenever the panel is
    /// open or showing alerts. `NotchLayout.acceptsClick(at:in:isShowingAlert:)` documents why this cannot be
    /// solved with a `hitTest(_:)` override.
    private func updateInteractivity(for state: NotchState) {
        // Collapsed, the window is click-through, so AppKit will never deliver
        // `draggingEntered` for a file that is merely approaching the notch.
        // While that drag is inside the extended region, accept events so the
        // drop can land. Anywhere else stays click-through.
        let inFileDrag = lastFileDrag && stateMachine.layout.hitRegion(for: state, fileDrag: true).contains(lastPointer)
        let accepts = inFileDrag || stateMachine.layout.acceptsClick(
            at: lastPointer,
            in: state,
            isShowingAlert: isAlertShowing
        )
        window?.setInteractive(accepts)
    }

    private func handlePointer(_ location: CGPoint, isDragging: Bool) {
        lastPointer = location
        if !isDragging {
            if wasDragging {
                finishFileDrag(at: location)
            }
            wasDragging = false
            lastFileDrag = false
            stateMachine.pointerMoved(to: location, fileDrag: false)
            updateInteractivity(for: stateMachine.state)
            return
        }

        wasDragging = true
        let urls = latchFileDragURLs()
        lastFileDrag = urls != nil
        stateMachine.pointerMoved(to: location, fileDrag: lastFileDrag)
        updateInteractivity(for: stateMachine.state)
        if let urls {
            noteFileDragMoved(urls, at: location)
        }
    }

    /// Reads the drag pasteboard at most once per drag. Empty types are not
    /// cached: Finder fills the pasteboard a frame or two after the drag starts.
    private func latchFileDragURLs() -> [URL]? {
        let pasteboard = NSPasteboard(name: .drag)
        let changeCount = pasteboard.changeCount
        guard changeCount != idleDragChangeCount else { return nil }
        if let latchedFileDrag {
            if latchedFileDrag.changeCount != changeCount {
                // Escape, or a second drag replacing this one, clears the
                // pasteboard. Do not commit the files we snapshotted.
                self.latchedFileDrag = nil
                idleDragChangeCount = changeCount
                cancelActiveFileDrag()
                return nil
            }
            return latchedFileDrag.urls.isEmpty ? nil : latchedFileDrag.urls
        }

        let urls = Self.readFileURLs(from: pasteboard)
        if !urls.isEmpty {
            latchedFileDrag = (changeCount, urls)
            return urls
        }
        if let types = pasteboard.types, !types.isEmpty,
           !types.contains(.fileURL), !types.contains(Self.filenamesPasteboardType) {
            latchedFileDrag = (changeCount, [])
        }
        return nil
    }

    private func noteFileDragMoved(_ urls: [URL], at location: CGPoint) {
        let inside = stateMachine.layout.hitRegion(for: stateMachine.state, fileDrag: true).contains(location)
        if activeFileDrag == nil {
            activeFileDrag = ActiveFileDrag(urls: urls, inside: false)
        } else {
            activeFileDrag?.urls = urls
        }
        guard let wasInside = activeFileDrag?.inside, wasInside != inside else { return }
        activeFileDrag?.inside = inside
        if inside {
            Log.hover.notice("hover: file drag entered")
            NotificationCenter.default.post(name: .notchFileDragEntered, object: nil)
        } else {
            NotificationCenter.default.post(name: .notchFileDragExited, object: nil)
        }
    }

    private func cancelActiveFileDrag() {
        guard let active = activeFileDrag else { return }
        activeFileDrag = nil
        if active.inside {
            NotificationCenter.default.post(name: .notchFileDragExited, object: nil)
        }
    }

    private func finishFileDrag(at location: CGPoint) {
        idleDragChangeCount = NSPasteboard(name: .drag).changeCount
        latchedFileDrag = nil
        guard let active = activeFileDrag else { return }
        activeFileDrag = nil
        let inside = stateMachine.layout.hitRegion(for: stateMachine.state, fileDrag: true).contains(location)
        if inside {
            NotificationCenter.default.post(name: .notchFileDropped, object: active.urls)
        } else if active.inside {
            NotificationCenter.default.post(name: .notchFileDragExited, object: nil)
        }
    }

    private static let filenamesPasteboardType = NSPasteboard.PasteboardType("NSFilenamesPboardType")

    private static func readFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        var urls: [URL] = []
        if let items = pasteboard.pasteboardItems {
            for item in items {
                guard let value = item.string(forType: .fileURL),
                      let url = URL(string: value), url.isFileURL else { continue }
                urls.append(url)
            }
        }
        if !urls.isEmpty { return urls }
        if let paths = pasteboard.propertyList(forType: filenamesPasteboardType) as? [String] {
            return paths.map { URL(fileURLWithPath: $0) }
        }
        return []
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

