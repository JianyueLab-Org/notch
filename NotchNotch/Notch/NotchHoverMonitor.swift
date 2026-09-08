//
//  NotchHoverMonitor.swift
//  NotchNotch
//
//  Turns "where is the cursor" into a stream of screen-coordinate points.
//  Knows nothing about the notch; the state machine does the hit testing.
//

import AppKit
import OSLog

@MainActor
final class NotchHoverMonitor {

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var pollTimer: Timer?

    private let onMove: (CGPoint, Bool) -> Void

    /// The events worth watching. Drags are included so the panel still tracks
    /// the cursor while a file is being dragged around (Phase 2 needs that, and
    /// it costs nothing now).
    private static let mask: NSEvent.EventTypeMask = [
        .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
    ]

    init(onMove: @escaping (CGPoint, Bool) -> Void) {
        self.onMove = onMove
    }

    func start() {
        guard globalMonitor == nil else { return }

        // A *global* monitor only sees events destined for OTHER applications.
        // That is exactly what we need while collapsed (the window is
        // click-through, so every move belongs to somebody else) and exactly
        // what stops working the moment the cursor is over our own expanded
        // panel...
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.mask) { [weak self] event in
            // AppKit delivers these on the main thread. `assumeIsolated` asserts
            // that rather than hopping, so a future AppKit change would trap
            // loudly here instead of racing silently.
            MainActor.assumeIsolated {
                let isDragging = [.leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(event.type)
                self?.deliverCurrentLocation(isDragging: isDragging)
            }
        }

        // ...so we also install a *local* monitor, which runs inside
        // NSApplication.sendEvent and therefore sees the moves the global one
        // cannot. Returning the event unchanged keeps normal dispatch intact.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.mask) { [weak self] event in
            MainActor.assumeIsolated {
                let isDragging = [.leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(event.type)
                self?.deliverCurrentLocation(isDragging: isDragging)
            }
            return event
        }

        startPolling()
        Log.hover.notice("hover: monitors installed")
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        stopPolling()
        Log.hover.notice("hover: monitors removed")
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        let interval = Double(NotchConfiguration.pointerPollInterval.components.seconds)
            + Double(NotchConfiguration.pointerPollInterval.components.attoseconds) / 1e18
        let timer = Timer(timeInterval: max(0.02, interval), repeats: true) { [weak self] _ in
            guard let self else { return }
            let isDragging = (NSEvent.pressedMouseButtons & 1) != 0
            self.onMove(NSEvent.mouseLocation, isDragging)
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func setPollingEnabled(_ enabled: Bool) {
        // Continuous polling is active
    }

    /// Read the cursor from `NSEvent.mouseLocation` rather than the event's own
    /// `locationInWindow`: for a global monitor there is no window to convert
    /// from, and this is already in the screen space everything else uses.
    private func deliverCurrentLocation(isDragging: Bool) {
        onMove(NSEvent.mouseLocation, isDragging)
    }

    isolated deinit {
        pollTimer?.invalidate()
    }
}
