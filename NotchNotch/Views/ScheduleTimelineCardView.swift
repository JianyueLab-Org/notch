//
//  ScheduleTimelineCardView.swift
//  NotchNotch
//
//  Schedule card with custom orange tick ruler gauge and upcoming event status.
//  Matches benchmark layout: event-specific orange capsules, -15m/+15m/+45m markers,
//  and right-aligned countdown footer.
//

import SwiftUI

struct ScheduleTimelineCardView: View {

    @ObservedObject var schedule: ScheduleController
    @ObservedObject private var loc = LocalizationManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            header
            Spacer(minLength: 4)
            rulerGauge
            timeMarkers
            Spacer(minLength: 4)
            footer
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .jylCard()
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(displayTitle)
                .font(.system(size: 14.5, weight: .bold, design: .rounded))
                .foregroundStyle(JYLTheme.textPrimary)
                .lineLimit(1)
            Text(displayStatus)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(JYLTheme.textSecondary)
                .lineLimit(1)
        }
    }

    private var displayTitle: String {
        if schedule.currentEventTitle == "No Scheduled Events" {
            return L10n.tr(.scheduleNoEvents)
        }
        if schedule.currentEventTitle == "Calendar Access Required" {
            return loc.isChinese ? "需要日历访问权限" : "Calendar Access Required"
        }
        return schedule.currentEventTitle
    }

    private var displayStatus: String {
        if schedule.currentEventStatus == "Calendar is clear" {
            return loc.isChinese ? "暂无日程安排" : "Calendar is clear"
        }
        if schedule.currentEventStatus == "No more events today" {
            return loc.isChinese ? "今日暂无后续日程" : "No more events today"
        }
        if schedule.currentEventStatus == "Enable in System Settings > Privacy" {
            return loc.isChinese ? "请在「系统设置 > 隐私」中开启" : "Enable in System Settings > Privacy"
        }
        return schedule.currentEventStatus
    }

    // MARK: - Ruler Gauge

    private var rulerGauge: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let tickCount = 37

            // 60-minute window: -15m to +45m. "Now" is at 15/60 = 25% of width.
            let nowFraction: CGFloat = 0.25
            let nowX = width * nowFraction

            // Compute event capsule bounds
            let (activeStartFrac, activeEndFrac, nextStartFrac, nextEndFrac) = computeEventFractions()

            let activeStartX = width * activeStartFrac
            let activeEndX = width * activeEndFrac
            let hasActiveCapsule = activeEndX > activeStartX + 6

            let nextStartX = width * nextStartFrac
            let nextEndX = width * nextEndFrac
            let hasNextCapsule = nextEndX > nextStartX + 6

            ZStack(alignment: .leading) {
                // Background ticks + event capsules
                Canvas { context, size in
                    let w = size.width
                    let h = size.height

                    // 1. Draw Active Event Capsule if present
                    if hasActiveCapsule {
                        let capsuleRect = CGRect(
                            x: activeStartX,
                            y: 1.0,
                            width: max(16, activeEndX - activeStartX),
                            height: h - 2.0
                        )
                        let path = Path(roundedRect: capsuleRect, cornerRadius: (h - 2.0) / 2)
                        context.fill(path, with: .color(JYLTheme.primaryMuted.opacity(0.85)))
                        context.stroke(path, with: .color(JYLTheme.primary), lineWidth: 1.2)
                    }

                    // 2. Draw Next Event Capsule if present
                    if hasNextCapsule {
                        let capsuleRect = CGRect(
                            x: nextStartX,
                            y: 1.0,
                            width: max(16, nextEndX - nextStartX),
                            height: h - 2.0
                        )
                        let path = Path(roundedRect: capsuleRect, cornerRadius: (h - 2.0) / 2)
                        context.fill(path, with: .color(JYLTheme.primaryMuted.opacity(0.85)))
                        context.stroke(path, with: .color(JYLTheme.primary), lineWidth: 1.2)
                    }

                    // 3. Draw vertical tick marks
                    let step = (w - 4) / CGFloat(tickCount - 1)
                    for i in 0..<tickCount {
                        let x = 2 + CGFloat(i) * step
                        let frac = x / w

                        let inActive = hasActiveCapsule && (frac >= activeStartFrac && frac <= activeEndFrac)
                        let inNext = hasNextCapsule && (frac >= nextStartFrac && frac <= nextEndFrac)
                        let isEventTick = inActive || inNext

                        let isMajor = (i % 6 == 0)
                        let tickHeight: CGFloat = isMajor ? 12 : 7.5
                        let tickY = (h - tickHeight) / 2
                        let tickWidth: CGFloat = 1.0
                        let tickRect = CGRect(x: x - tickWidth / 2, y: tickY, width: tickWidth, height: tickHeight)

                        let tickColor: Color = isEventTick ? JYLTheme.primary : JYLTheme.neutral600.opacity(0.8)
                        context.fill(Path(tickRect), with: .color(tickColor))
                    }
                }

                // "Now" Translucent Capsule Cursor Slider
                ZStack {
                    Capsule()
                        .fill(Color.white.opacity(0.28))
                        .overlay(
                            Capsule().strokeBorder(Color.white.opacity(0.85), lineWidth: 1.0)
                        )
                        .frame(width: 8, height: 18)

                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 1.2, height: 10)
                }
                .offset(x: nowX - 4)
            }
        }
        .frame(height: 20)
    }

    /// Calculates relative fraction [0...1] within the [-15m, +45m] timeline window
    private func computeEventFractions() -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        let now = Date()
        let windowStart = now.addingTimeInterval(-15 * 60)
        let totalSpan: TimeInterval = 60 * 60

        if schedule.isAuthorized {
            if let start = schedule.currentEventStartDate, let end = schedule.currentEventEndDate {
                let sFrac = CGFloat(max(0, min(1.0, start.timeIntervalSince(windowStart) / totalSpan)))
                let eFrac = CGFloat(max(0, min(1.0, end.timeIntervalSince(windowStart) / totalSpan)))

                var nStartFrac: CGFloat = 0
                var nEndFrac: CGFloat = 0
                if let nStart = schedule.nextEventStartDate, let nEnd = schedule.nextEventEndDate {
                    nStartFrac = CGFloat(max(0, min(1.0, nStart.timeIntervalSince(windowStart) / totalSpan)))
                    nEndFrac = CGFloat(max(0, min(1.0, nEnd.timeIntervalSince(windowStart) / totalSpan)))
                }

                return (sFrac, eFrac, nStartFrac, nEndFrac)
            } else if let nStart = schedule.nextEventStartDate, let nEnd = schedule.nextEventEndDate {
                let nStartFrac = CGFloat(max(0, min(1.0, nStart.timeIntervalSince(windowStart) / totalSpan)))
                let nEndFrac = CGFloat(max(0, min(1.0, nEnd.timeIntervalSince(windowStart) / totalSpan)))
                return (0, 0, nStartFrac, nEndFrac)
            } else {
                return (0, 0, 0, 0)
            }
        } else {
            // Preview / Demo state matching benchmark screenshot:
            // Active event spans from 25% (now) to 84%, next event from 91% to 99%
            return (0.25, 0.84, 0.91, 0.99)
        }
    }

    // MARK: - Time Markers

    private var timeMarkers: some View {
        HStack {
            Text("-15m")
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundStyle(JYLTheme.textMuted)
            Spacer()
            Text("+15m")
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundStyle(JYLTheme.textMuted)
            Spacer()
            Text("+45m")
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundStyle(JYLTheme.textMuted)
        }
        .padding(.horizontal, 4)
        .frame(height: 13)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2)
                    .stroke(JYLTheme.primary, style: StrokeStyle(lineWidth: 1.1, dash: [2, 1.5]))
                    .frame(width: 8, height: 8)
                Text("\(loc.isChinese ? "下个日程" : "Next") · \(displayNextTitle)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(JYLTheme.textPrimary)
                    .lineLimit(1)
            }
            Spacer()
            Text(schedule.nextEventTime)
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(JYLTheme.textMuted)
        }
    }

    private var displayNextTitle: String {
        if schedule.nextEventTitle == "No Scheduled Events" || schedule.nextEventTitle.isEmpty {
            return L10n.tr(.scheduleNoEvents)
        }
        return schedule.nextEventTitle
    }
}
