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

@MainActor
final class ScheduleController: ObservableObject {

    @Published var currentEventTitle: String = "Business Management"
    @Published var currentEventStatus: String = "In progress · 1hr 40min"
    @Published var progress: Double = 0.42
    @Published var nextEventTitle: String = "Japanese"
    @Published var nextEventTime: String = "in 1hr 17min"

    private let eventStore = EKEventStore()
    private var timerCancellable: AnyCancellable?

    init() {
        start()
    }

    func start() {
        checkPermissionAndFetch()
        // Periodically refresh every minute
        timerCancellable = Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.checkPermissionAndFetch()
            }
    }

    func checkPermissionAndFetch() {
        let status = EKEventStore.authorizationStatus(for: .event)
        #if compiler(>=5.9)
        if #available(macOS 14.0, *) {
            if status == .fullAccess {
                fetchEvents()
                return
            }
        }
        #endif
        if status == .authorized {
            fetchEvents()
        }
    }

    private func fetchEvents() {
        let now = Date()
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: now)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else { return }

        let predicate = eventStore.predicateForEvents(withStart: startOfDay, end: endOfDay, calendars: nil)
        let events = eventStore.events(matching: predicate).sorted { $0.startDate < $1.startDate }

        if let current = events.first(where: { $0.startDate <= now && $0.endDate > now }) {
            currentEventTitle = current.title
            let elapsed = now.timeIntervalSince(current.startDate)
            let total = current.endDate.timeIntervalSince(current.startDate)
            progress = max(0.05, min(0.95, elapsed / max(1, total)))
            let remaining = current.endDate.timeIntervalSince(now)
            currentEventStatus = "In progress · \(formatDuration(remaining))"

            if let next = events.first(where: { $0.startDate >= current.endDate }) {
                nextEventTitle = next.title
                let until = next.startDate.timeIntervalSince(now)
                nextEventTime = "in \(formatDuration(until))"
            }
        } else if let next = events.first(where: { $0.startDate > now }) {
            currentEventTitle = next.title
            let until = next.startDate.timeIntervalSince(now)
            currentEventStatus = "Starts in \(formatDuration(until))"
            progress = 0.1

            let afterNext = events.first(where: { $0.startDate > next.startDate })
            if let after = afterNext {
                nextEventTitle = after.title
                let afterUntil = after.startDate.timeIntervalSince(now)
                nextEventTime = "in \(formatDuration(afterUntil))"
            }
        }
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let minutes = max(1, Int(interval) / 60)
        if minutes < 60 {
            return "\(minutes)min"
        } else {
            let hours = minutes / 60
            let remMin = minutes % 60
            return remMin == 0 ? "\(hours)hr" : "\(hours)hr \(remMin)min"
        }
    }
}
