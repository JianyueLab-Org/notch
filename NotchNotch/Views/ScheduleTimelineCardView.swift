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
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color(white: 0.11))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.15), Color.white.opacity(0.04)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.5
                        )
                )
        )
    }

    // MARK: - Components

    private var header: some View {
        VStack(alignment: .leading, spacing: 1.5) {
            Text(schedule.currentEventTitle)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(schedule.currentEventStatus)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(1)
        }
    }

    private var rulerGauge: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let tickCount = 33 // 4 blocks of 8 subdivisions (indices 0, 8, 16, 24, 32)
            let thumbX = 5 + (width - 10) * schedule.progress

            ZStack(alignment: .leading) {
                // Outer orange capsule boundary
                Capsule()
                    .stroke(
                        LinearGradient(
                            colors: [Color(red: 1.0, green: 0.60, blue: 0.05), Color(red: 1.0, green: 0.50, blue: 0.0)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1.1
                    )
                    .background(Capsule().fill(Color.orange.opacity(0.06)))

                // Consolidated single-pass GPU Canvas: background block dividers + ticks
                Canvas { context, size in
                    let w = size.width - 10
                    let h = size.height

                    // 1. Subtle 15-minute block divider lines (at 25%, 50%, 75%)
                    let blockFractions: [CGFloat] = [0.25, 0.50, 0.75]
                    for frac in blockFractions {
                        let x = 5 + frac * w
                        let dividerPath = Path(CGRect(x: x - 0.5, y: 3.0, width: 1, height: h - 6))
                        context.fill(dividerPath, with: .color(Color.white.opacity(0.10)))
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
                            context.fill(Path(tickRect), with: .color(Color.white.opacity(0.90)))
                        } else {
                            let category = schedule.tickCategory(at: i)
                            let color: Color
                            switch category {
                            case .past:
                                color = Color(red: 1.0, green: 0.58, blue: 0.05)
                            case .currentEvent:
                                color = isBlockBoundary ? Color(red: 1.0, green: 0.65, blue: 0.12) : Color.orange.opacity(0.60)
                            case .nextEvent:
                                color = Color.orange.opacity(0.32)
                            case .pastEmpty:
                                color = Color.white.opacity(0.18)
                            case .freeTime:
                                color = Color.white.opacity(0.20)
                            }
                            context.fill(Path(tickRect), with: .color(color))
                        }
                    }
                }

                // White slider thumb indicator
                ZStack {
                    Capsule()
                        .fill(Color.white.opacity(0.35))
                        .overlay(Capsule().stroke(Color.white, lineWidth: 1.1))
                        .frame(width: 8, height: 18)
                    Rectangle()
                        .fill(Color.white)
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
                .foregroundStyle(Color.white.opacity(0.48))
            Spacer()
            Text("0")
                .font(.system(size: 8.5, weight: .bold, design: .rounded))
                .foregroundStyle(Color(red: 1.0, green: 0.65, blue: 0.15))
            Spacer()
            Text("15")
                .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.48))
            Spacer()
            Text("30")
                .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.48))
            Spacer()
            Text("45")
                .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.48))
        }
        .padding(.horizontal, 4)
        .frame(height: 11)
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 4.5) {
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color(red: 1.0, green: 0.58, blue: 0.05), style: StrokeStyle(lineWidth: 1.1, dash: [2, 1.5]))
                    .frame(width: 7.5, height: 7.5)
                Text("Next · \(schedule.nextEventTitle)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            Spacer()
            Text(schedule.nextEventTime)
                .font(.system(size: 10, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
        }
    }
}
