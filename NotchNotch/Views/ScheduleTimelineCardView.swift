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
                .fill(Color.white.opacity(0.08))
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
                .foregroundStyle(.white.opacity(0.6))
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
                    .stroke(Color.orange.opacity(0.85), lineWidth: 1.4)
                    .background(Capsule().fill(Color.black.opacity(0.2)))

                // Vertical tick marks
                HStack(spacing: 0) {
                    ForEach(0..<tickCount, id: \.self) { i in
                        let isPastThumb = Double(i) / Double(tickCount) < schedule.progress
                        let isNextEvent = i >= dividerIndex

                        if i == dividerIndex {
                            // Divider bar separating current event from next event
                            Rectangle()
                                .fill(Color.white.opacity(0.6))
                                .frame(width: 1.5, height: 16)
                                .frame(maxWidth: .infinity)
                        } else {
                            Rectangle()
                                .fill(
                                    isPastThumb
                                        ? Color.orange
                                        : (isNextEvent ? Color.orange.opacity(0.65) : Color.orange.opacity(0.35))
                                )
                                .frame(width: 1.5, height: 13)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(.horizontal, 6)

                // White slider thumb indicator
                ZStack {
                    Capsule()
                        .fill(Color.white.opacity(0.28))
                        .overlay(Capsule().stroke(Color.white, lineWidth: 1.4))
                        .frame(width: 10, height: 22)
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 1.5, height: 14)
                }
                .offset(x: thumbX - 5)
            }
        }
        .frame(height: 24)
    }

    private var timeMarkers: some View {
        HStack {
            Text("-15m")
            Spacer()
            Text("+15m")
            Spacer()
            Text("+45m")
        }
        .font(.system(size: 10, weight: .medium, design: .rounded))
        .foregroundStyle(.white.opacity(0.4))
        .padding(.horizontal, 6)
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2.5)
                    .stroke(Color.orange, style: StrokeStyle(lineWidth: 1.2, dash: [2, 1.5]))
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
