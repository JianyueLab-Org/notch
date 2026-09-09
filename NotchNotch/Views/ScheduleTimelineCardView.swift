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
        VStack(alignment: .leading, spacing: 4) {
            header
            Spacer(minLength: 4)
            rulerGauge
            timeMarkers
            Spacer(minLength: 4)
            footer
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(white: 0.11))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
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
        .compositingGroup()
    }

    // MARK: - Components

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(schedule.currentEventTitle)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(schedule.currentEventStatus)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(1)
        }
    }

    private var rulerGauge: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let tickCount = 33 // 4 blocks of 8 subdivisions (indices 0, 8, 16, 24, 32)
            let thumbX = 6 + (width - 12) * schedule.progress

            ZStack(alignment: .leading) {
                // Outer orange capsule boundary
                Capsule()
                    .stroke(
                        LinearGradient(
                            colors: [Color(red: 1.0, green: 0.60, blue: 0.05), Color(red: 1.0, green: 0.50, blue: 0.0)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1.2
                    )
                    .background(Capsule().fill(Color.orange.opacity(0.06)))

                // Consolidated single-pass GPU Canvas: background block dividers + ticks
                Canvas { context, size in
                    let w = size.width - 12
                    let h = size.height

                    // 1. Subtle 15-minute block divider lines (at 25%, 50%, 75%)
                    let blockFractions: [CGFloat] = [0.25, 0.50, 0.75]
                    for frac in blockFractions {
                        let x = 6 + frac * w
                        let dividerPath = Path(CGRect(x: x - 0.5, y: 3.5, width: 1, height: h - 7))
                        context.fill(dividerPath, with: .color(Color.white.opacity(0.10)))
                    }

                    // 2. Vertical tick marks (33 ticks: 4 blocks of 8 subdivisions)
                    let step = w / CGFloat(tickCount - 1)
                    for i in 0..<tickCount {
                        let x = 6 + CGFloat(i) * step
                        let isBlockBoundary = (i % 8 == 0)
                        let isDivider = (schedule.dividerIndex != nil && i == schedule.dividerIndex)

                        let tickHeight: CGFloat = isBlockBoundary ? 16 : 10
                        let tickWidth: CGFloat = isBlockBoundary ? 1.6 : 1.2
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
                        .overlay(Capsule().stroke(Color.white, lineWidth: 1.2))
                        .frame(width: 10, height: 22)
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 1.5, height: 13)
                }
                .offset(x: thumbX - 5)
            }
        }
        .frame(height: 24)
    }

    private var timeMarkers: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let labels = ["-15", "0", "15", "30", "45"]
            let fractions: [CGFloat] = [0.0, 0.25, 0.50, 0.75, 1.0]

            ZStack {
                ForEach(0..<labels.count, id: \.self) { idx in
                    let frac = fractions[idx]
                    let x = 6 + frac * (w - 12)
                    Text(labels[idx])
                        .font(.system(size: 9.5, weight: idx == 1 ? .bold : .semibold, design: .rounded))
                        .foregroundStyle(idx == 1 ? Color(red: 1.0, green: 0.65, blue: 0.15) : Color.white.opacity(0.48))
                        .position(x: x, y: geo.size.height / 2)
                }
            }
        }
        .frame(height: 14)
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2.5)
                    .stroke(Color(red: 1.0, green: 0.58, blue: 0.05), style: StrokeStyle(lineWidth: 1.2, dash: [2, 1.5]))
                    .frame(width: 9, height: 9)
                Text("Next · \(schedule.nextEventTitle)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            Spacer()
            Text(schedule.nextEventTime)
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
        }
    }
}
