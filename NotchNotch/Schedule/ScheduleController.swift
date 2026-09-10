//
//  ScheduleController.swift
//  NotchNotch
//
//  Manages current schedule timeline, task progress, and upcoming events.
//

import AppKit
import Combine
import EventKit
import SwiftUI

struct EventSnapshot: Sendable {
    let title: String?
    let startDate: Date
    let endDate: Date
}

enum ScheduleAlertType: Equatable {
    case startsSoon(title: String, date: Date)
    case endsSoon(title: String, date: Date)

    var title: String {
        switch self {
        case .startsSoon(let title, _): return title
        case .endsSoon(let title, _): return title
        }
    }

    var badgeText: String {
        switch self {
        case .startsSoon: return "10 分钟后开始"
        case .endsSoon: return "还有 10 分钟结束"
        }
    }

    var iconName: String {
        switch self {
        case .startsSoon: return "calendar.badge.clock"
        case .endsSoon: return "clock.badge.exclamationmark"
        }
    }

    var tintColor: Color {
        switch self {
        case .startsSoon: return Color(red: 0.98, green: 0.65, blue: 0.16)
        case .endsSoon: return Color(red: 0.95, green: 0.35, blue: 0.35)
        }
    }
}

actor CalendarReader {
    private let eventStore = EKEventStore()

    func fetchEvents(start: Date, end: Date) -> [EventSnapshot] {
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        return eventStore.events(matching: predicate)
            .filter { !$0.isAllDay && $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
            .map { EventSnapshot(title: $0.title, startDate: $0.startDate, endDate: $0.endDate) }
    }

    func requestFullAccess() async -> Bool {
        #if compiler(>=5.9)
        if #available(macOS 14.0, *) {
            return (try? await eventStore.requestFullAccessToEvents()) ?? false
        }
        #endif
        return await withCheckedContinuation { continuation in
            eventStore.requestAccess(to: .event) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }
}

@MainActor
final class ScheduleController: ObservableObject {

    static let shared = ScheduleController()
    static let reminderEnabledKey = "co.jianyuelab.NotchNotch.scheduleReminderEnabled"

    @Published var currentEventTitle: String = "No Scheduled Events"
    @Published var currentEventStatus: String = "Calendar is clear"
    @Published var progress: Double = 0.0
    @Published var nextEventTitle: String = "All Clear"
    @Published var nextEventTime: String = "today"
    @Published var isAuthorized: Bool = false
    @Published var dividerIndex: Int? = nil
    @Published var hasActiveEvent: Bool = false

    // Event interval data for timeline ruler rendering:
    @Published var currentEventStartDate: Date?
    @Published var currentEventEndDate: Date?
    @Published var nextEventStartDate: Date?
    @Published var nextEventEndDate: Date?

    // 10-minute Reminders & Alert banner:
    @Published var activeAlert: ScheduleAlertType? = nil
    @Published var isShowingAlert: Bool = false
    @Published var isReminderEnabled: Bool = true

    private var sentReminderKeys: Set<String> = []
    private var alertDismissTimer: Timer?

    private let reader = CalendarReader()
    private var cancellables: Set<AnyCancellable> = []

    init() {
        if UserDefaults.standard.object(forKey: Self.reminderEnabledKey) != nil {
            self.isReminderEnabled = UserDefaults.standard.bool(forKey: Self.reminderEnabledKey)
        } else {
            self.isReminderEnabled = true
        }
        start()
    }

    func start() {
        checkPermissionAndFetch()

        // Listen for EventKit calendar database changes (Calendar.app, iCloud, Google, etc.)
        NotificationCenter.default.publisher(for: .EKEventStoreChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.fetchEvents()
            }
            .store(in: &cancellables)

        // Refresh every 15 seconds to keep relative minutes and progress up to date
        Timer.publish(every: 15, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.fetchEvents()
            }
            .store(in: &cancellables)
    }

    func checkPermissionAndFetch() {
        let status = EKEventStore.authorizationStatus(for: .event)
        #if compiler(>=5.9)
        if #available(macOS 14.0, *) {
            switch status {
            case .fullAccess:
                isAuthorized = true
                fetchEvents()
            case .notDetermined:
                requestPermission()
            case .authorized:
                isAuthorized = true
                fetchEvents()
            case .restricted, .denied:
                handlePermissionDenied()
            @unknown default:
                break
            }
            return
        }
        #endif

        switch status {
        case .authorized:
            isAuthorized = true
            fetchEvents()
        case .notDetermined:
            requestPermission()
        case .restricted, .denied:
            handlePermissionDenied()
        @unknown default:
            break
        }
    }

    private func requestPermission() {
        Task {
            let granted = await reader.requestFullAccess()
            if granted {
                self.isAuthorized = true
                self.fetchEvents()
            } else {
                self.handlePermissionDenied()
            }
        }
    }

    private func handlePermissionDenied() {
        isAuthorized = false
        hasActiveEvent = false
        currentEventTitle = "Calendar Access Required"
        currentEventStatus = "Enable in System Settings > Privacy"
        nextEventTitle = "Calendar"
        nextEventTime = "not authorized"
    }

    private func fetchEvents() {
        let status = EKEventStore.authorizationStatus(for: .event)
        #if compiler(>=5.9)
        if #available(macOS 14.0, *) {
            guard status == .fullAccess || status == .authorized else { return }
        } else {
            guard status == .authorized else { return }
        }
        #else
        guard status == .authorized else { return }
        #endif

        let now = Date()
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: now)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else { return }

        // Offload database query to background CalendarReader actor so main thread 120fps animations are never hitched
        Task { [weak self] in
            guard let self else { return }
            let snapshots = await self.reader.fetchEvents(start: startOfDay, end: endOfDay)
            self.processEvents(snapshots, now: now, endOfDay: endOfDay)
        }
    }

    func processEvents(_ rawEvents: [EventSnapshot], now: Date, endOfDay: Date? = nil) {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: now)
        let resolvedEndOfDay = endOfDay ?? (calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay.addingTimeInterval(86400))

        // Strictly filter to events belonging to today (startDate strictly before tomorrow / endOfDay)
        let todayEvents = rawEvents.filter { $0.startDate < resolvedEndOfDay }

        let current = todayEvents.first(where: { $0.startDate <= now && $0.endDate > now })
        let next = todayEvents.first(where: { $0.startDate > now })

        if let current {
            hasActiveEvent = true
            currentEventTitle = current.title ?? "Untitled Event"
            currentEventStartDate = current.startDate
            currentEventEndDate = current.endDate

            let total = current.endDate.timeIntervalSince(current.startDate)
            let elapsed = now.timeIntervalSince(current.startDate)
            progress = total > 0 ? min(1.0, max(0.04, elapsed / total)) : 0.25

            let remaining = max(0, current.endDate.timeIntervalSince(now))
            if elapsed < 300 {
                currentEventStatus = "Starting now · \(formatDuration(total))"
            } else {
                currentEventStatus = "In progress · \(formatDuration(remaining)) left"
            }

            // Compute divider tick if current event ends within the [-15min, +45min] window
            let endMinutes = current.endDate.timeIntervalSince(now) / 60.0
            if endMinutes <= 45.0 {
                let fraction = (endMinutes + 15.0) / 60.0
                dividerIndex = Int(round(fraction * 32.0))
            } else {
                dividerIndex = nil
            }

            if let nextEvent = todayEvents.first(where: { $0.startDate >= current.endDate }) {
                nextEventTitle = nextEvent.title ?? "Untitled Event"
                nextEventStartDate = nextEvent.startDate
                nextEventEndDate = nextEvent.endDate
                let until = max(0, nextEvent.startDate.timeIntervalSince(now))
                nextEventTime = "in \(formatDuration(until))"
            } else {
                nextEventTitle = "No more events"
                nextEventTime = "today"
                nextEventStartDate = nil
                nextEventEndDate = nil
            }
        } else if let next {
            hasActiveEvent = false
            progress = 0.0
            currentEventTitle = next.title ?? "Untitled Event"
            currentEventStartDate = next.startDate
            currentEventEndDate = next.endDate

            let until = max(0, next.startDate.timeIntervalSince(now))
            currentEventStatus = "Starts in \(formatDuration(until)) · \(formatClock(next.startDate))"

            // Compute divider tick if next event starts within the window
            let startMinutes = next.startDate.timeIntervalSince(now) / 60.0
            if startMinutes <= 45.0 {
                let fraction = (startMinutes + 15.0) / 60.0
                dividerIndex = Int(round(fraction * 32.0))
            } else {
                dividerIndex = nil
            }

            let afterNext = todayEvents.first(where: { $0.startDate >= next.endDate })
            if let after = afterNext {
                nextEventTitle = after.title ?? "Untitled Event"
                nextEventStartDate = after.startDate
                nextEventEndDate = after.endDate
                let afterUntil = max(0, after.startDate.timeIntervalSince(now))
                nextEventTime = "in \(formatDuration(afterUntil))"
            } else {
                nextEventTitle = "No more events"
                nextEventTime = "today"
                nextEventStartDate = nil
                nextEventEndDate = nil
            }
        } else {
            hasActiveEvent = false
            progress = 0.0
            currentEventTitle = "No Scheduled Events"
            currentEventStatus = todayEvents.isEmpty ? "Calendar is clear" : "No more events today"
            nextEventTitle = "All Clear"
            nextEventTime = "today"
            dividerIndex = nil
            currentEventStartDate = nil
            currentEventEndDate = nil
            nextEventStartDate = nil
            nextEventEndDate = nil
        }

        if isReminderEnabled {
            checkReminders(events: todayEvents, now: now)
        }
    }

    // MARK: - Reminders & Alerts

    func setReminderEnabled(_ enabled: Bool) {
        isReminderEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.reminderEnabledKey)
        if !enabled {
            dismissAlert()
        }
    }

    func triggerAlert(_ alert: ScheduleAlertType) {
        activeAlert = alert
        isShowingAlert = true
        alertDismissTimer?.invalidate()
        alertDismissTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isShowingAlert = false
                self?.activeAlert = nil
            }
        }
    }

    func dismissAlert() {
        alertDismissTimer?.invalidate()
        alertDismissTimer = nil
        isShowingAlert = false
        activeAlert = nil
    }

    private func checkReminders(events: [EventSnapshot], now: Date) {
        if sentReminderKeys.count > 100 {
            sentReminderKeys.removeAll()
        }

        for event in events {
            guard let title = event.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            // 1. Starts soon: 10 minutes before start (within 540s ~ 660s)
            let startDiff = event.startDate.timeIntervalSince(now)
            if startDiff >= 540 && startDiff <= 660 {
                let key = "\(title)_\(Int(event.startDate.timeIntervalSince1970))_start10"
                if !sentReminderKeys.contains(key) {
                    sentReminderKeys.insert(key)
                    triggerAlert(.startsSoon(title: title, date: event.startDate))
                    break
                }
            }

            // 2. Ends soon: 10 minutes before end (within 540s ~ 660s) for active event
            let endDiff = event.endDate.timeIntervalSince(now)
            if event.startDate <= now && endDiff >= 540 && endDiff <= 660 {
                let key = "\(title)_\(Int(event.startDate.timeIntervalSince1970))_end10"
                if !sentReminderKeys.contains(key) {
                    sentReminderKeys.insert(key)
                    triggerAlert(.endsSoon(title: title, date: event.endDate))
                    break
                }
            }
        }
    }

    /// Evaluates which visual category a tick mark at index (0...32) belongs to.
    func tickCategory(at index: Int) -> TickCategory {
        let frac = Double(index) / 32.0
        let tickMinutes = -15.0 + frac * 60.0
        let isPast = tickMinutes < 0 // To the left of Now (0)

        // If not authorized or in initial demo state, use polished preview ticks
        guard isAuthorized else {
            if isPast {
                return .past
            } else if index < 24 {
                return .currentEvent
            } else {
                return .nextEvent
            }
        }

        let now = Date()
        let tickDate = now.addingTimeInterval(tickMinutes * 60.0)

        if let start = currentEventStartDate, let end = currentEventEndDate, tickDate >= start && tickDate <= end {
            return isPast ? .past : .currentEvent
        }

        if let start = nextEventStartDate, let end = nextEventEndDate, tickDate >= start && tickDate <= end {
            return .nextEvent
        }

        return isPast ? .pastEmpty : .freeTime
    }

    enum TickCategory {
        case past           // Past time within active event
        case pastEmpty      // Past time without event
        case currentEvent   // Remaining time of current event
        case nextEvent      // Upcoming event time
        case freeTime       // Unscheduled time
    }

    func formatDuration(_ interval: TimeInterval) -> String {
        let minutes = max(1, Int(interval) / 60)
        if minutes < 60 {
            return "\(minutes)m"
        } else {
            let hours = minutes / 60
            let remMin = minutes % 60
            return remMin == 0 ? "\(hours)hr" : "\(hours)hr \(remMin)m"
        }
    }

    private func formatClock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
