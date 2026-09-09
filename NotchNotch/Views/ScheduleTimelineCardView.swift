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
            let tickCount = 36
            let dividerIndex = Int(Double(tickCount) * 0.82)
            let thumbX = min(max(width * schedule.progress, 14), width - 14)

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

                // Vertical tick marks drawn via GPU Canvas
                Canvas { context, size in
                    let step = (size.width - 12) / CGFloat(tickCount - 1)
                    for i in 0..<tickCount {
                        let x = 6 + CGFloat(i) * step
                        let isPastThumb = Double(i) / Double(tickCount) < schedule.progress
                        let isNextEvent = i >= dividerIndex

                        let tickHeight: CGFloat = (i == dividerIndex) ? 15 : 13
                        let tickY = (size.height - tickHeight) / 2
                        let tickRect = CGRect(x: x - 0.75, y: tickY, width: 1.5, height: tickHeight)

                        if i == dividerIndex {
                            context.fill(Path(tickRect), with: .color(Color.white.opacity(0.6)))
                        } else if isPastThumb {
                            context.fill(Path(tickRect), with: .color(Color(red: 1.0, green: 0.58, blue: 0.05)))
                        } else if isNextEvent {
                            context.fill(Path(tickRect), with: .color(Color.orange.opacity(0.6)))
                        } else {
                            context.fill(Path(tickRect), with: .color(Color.orange.opacity(0.32)))
                        }
                    }
                }

                // White slider thumb indicator
                ZStack {
                    Capsule()
                        .fill(Color.white.opacity(0.32))
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
        HStack {
            Text("-15min")
            Spacer()
            Text("+15min")
            Spacer()
            Text("+45min")
        }
        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(0.42))
        .padding(.horizontal, 6)
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
