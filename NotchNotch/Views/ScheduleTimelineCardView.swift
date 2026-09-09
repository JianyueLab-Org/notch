//
//  ScheduleTimelineCardView.swift
//  NotchNotch
//
//  Schedule card with custom orange tick ruler gauge and upcoming event status.
//

import SwiftUI

struct ScheduleTimelineCardView: View {

    @ObservedObject var schedule: ScheduleController

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            header
            Spacer(minLength: 2)
            rulerGauge
            timeMarkers
            Spacer(minLength: 2)
            footer
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .jylCard()
    }

    // MARK: - Components

    private var header: some View {
        VStack(alignment: .leading, spacing: 1.5) {
            Text(schedule.currentEventTitle)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(JYLTheme.textPrimary)
                .lineLimit(1)
            Text(schedule.currentEventStatus)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(JYLTheme.textSecondary)
                .lineLimit(1)
        }
    }

    private var rulerGauge: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let tickCount = 33 // 4 blocks of 8 subdivisions (indices 0, 8, 16, 24, 32)
            let thumbX = 5 + (width - 10) * schedule.progress

            ZStack(alignment: .leading) {
                // Outer JYL primary capsule boundary
                Capsule()
                    .stroke(
                        LinearGradient(
                            colors: [JYLTheme.primary, JYLTheme.primaryHover],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1.1
                    )
                    .background(Capsule().fill(JYLTheme.primaryMuted))

                // Consolidated single-pass GPU Canvas: background block dividers + ticks
                Canvas { context, size in
                    let w = size.width - 10
                    let h = size.height

                    // 1. Subtle 15-minute block divider lines (at 25%, 50%, 75%)
                    let blockFractions: [CGFloat] = [0.25, 0.50, 0.75]
                    for frac in blockFractions {
                        let x = 5 + frac * w
                        let dividerPath = Path(CGRect(x: x - 0.5, y: 3.0, width: 1, height: h - 6))
                        context.fill(dividerPath, with: .color(JYLTheme.borderStrong.opacity(0.4)))
                    }

                    // 2. Vertical tick marks (33 ticks: 4 blocks of 8 subdivisions)
                    let step = w / CGFloat(tickCount - 1)
                    for i in 0..<tickCount {
                        let x = 5 + CGFloat(i) * step
                        let isBlockBoundary = (i % 8 == 0)
                        let isDivider = (schedule.dividerIndex != nil && i == schedule.dividerIndex)

                        let tickHeight: CGFloat = isBlockBoundary ? 13 : 8
                        let tickWidth: CGFloat = isBlockBoundary ? 1.4 : 1.0
                        let tickY = (h - tickHeight) / 2
                        let tickRect = CGRect(x: x - tickWidth / 2, y: tickY, width: tickWidth, height: tickHeight)

                        if isDivider {
                            context.fill(Path(tickRect), with: .color(JYLTheme.textPrimary))
                        } else {
                            let category = schedule.tickCategory(at: i)
                            let color: Color
                            switch category {
                            case .past:
                                color = JYLTheme.primary
                            case .currentEvent:
                                color = isBlockBoundary ? JYLTheme.primaryLight : JYLTheme.primary
                            case .nextEvent:
                                color = JYLTheme.primary.opacity(0.35)
                            case .pastEmpty:
                                color = JYLTheme.neutral700
                            case .freeTime:
                                color = JYLTheme.neutral600
                            }
                            context.fill(Path(tickRect), with: .color(color))
                        }
                    }
                }

                // Slider thumb indicator
                ZStack {
                    Capsule()
                        .fill(JYLTheme.neutral800.opacity(0.7))
                        .overlay(Capsule().stroke(JYLTheme.textPrimary, lineWidth: 1.1))
                        .frame(width: 8, height: 18)
                    Rectangle()
                        .fill(JYLTheme.textPrimary)
                        .frame(width: 1.2, height: 10)
                }
                .offset(x: thumbX - 4)
            }
        }
        .frame(height: 20)
    }

    private var timeMarkers: some View {
        HStack {
            Text("-15")
                .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                .foregroundStyle(JYLTheme.textMuted)
            Spacer()
            Text("0")
                .font(.system(size: 8.5, weight: .bold, design: .rounded))
                .foregroundStyle(JYLTheme.primaryLight)
            Spacer()
            Text("15")
                .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                .foregroundStyle(JYLTheme.textMuted)
            Spacer()
            Text("30")
                .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                .foregroundStyle(JYLTheme.textMuted)
            Spacer()
            Text("45")
                .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                .foregroundStyle(JYLTheme.textMuted)
        }
        .padding(.horizontal, 4)
        .frame(height: 11)
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 4.5) {
                RoundedRectangle(cornerRadius: 2)
                    .stroke(JYLTheme.primary, style: StrokeStyle(lineWidth: 1.1, dash: [2, 1.5]))
                    .frame(width: 7.5, height: 7.5)
                Text("Next · \(schedule.nextEventTitle)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(JYLTheme.textPrimary)
                    .lineLimit(1)
            }
            Spacer()
            Text(schedule.nextEventTime)
                .font(.system(size: 10, weight: .regular, design: .rounded))
                .foregroundStyle(JYLTheme.textMuted)
        }
    }
}
