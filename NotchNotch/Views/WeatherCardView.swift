//
//  WeatherCardView.swift
//  NotchNotch
//
//  Weather dashboard card view for the expanded notch panel.
//  Observes WeatherController.shared and displays current weather metrics
//  along with an interactive hourly forecast carousel.
//

import SwiftUI

struct WeatherCardView: View {
    @ObservedObject private var weather = WeatherController.shared
    @ObservedObject private var loc = LocalizationManager.shared

    @State private var isHoveringRefresh: Bool = false
    @State private var isHoveringRetry: Bool = false
    @State private var isAnimatingRefresh: Bool = false

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    var body: some View {
        Group {
            if let snapshot = weather.currentSnapshot {
                HStack(spacing: 10) {
                    leftOverviewCard(snapshot: snapshot)
                    rightHourlyCard(snapshot: snapshot)
                }
            } else {
                placeholderView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if weather.currentSnapshot == nil && !weather.isLoading {
                weather.refresh()
            }
        }
    }

    // MARK: - Placeholder / Empty / Error View

    private var placeholderView: some View {
        VStack(spacing: 12) {
            if let error = weather.lastError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(JYLTheme.warning)

                Text(loc.isChinese ? "获取天气失败" : "Weather Update Failed")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(JYLTheme.textPrimary)

                Text(error)
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(JYLTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 24)

                Button {
                    weather.refresh()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                        Text(L10n.tr(.weatherRetry))
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isHoveringRetry ? JYLTheme.surfaceRaisedSecondary : JYLTheme.surfaceRaised)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(JYLTheme.border, lineWidth: 0.8)
                            )
                    )
                    .foregroundStyle(JYLTheme.textPrimary)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isHoveringRetry = hovering
                    }
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .padding(.bottom, 2)

                Text(L10n.tr(.weatherFetching))
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(JYLTheme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .jylCard(cornerRadius: 13)
    }

    // MARK: - Left Card: Current Weather Overview

    private func leftOverviewCard(snapshot: WeatherSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header
            HStack(alignment: .center, spacing: 5) {
                Image(systemName: "location.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(JYLTheme.primary)

                let city = snapshot.cityName.isEmpty ? (weather.currentLocation?.cityName ?? (loc.isChinese ? "未知位置" : "Unknown")) : snapshot.cityName
                Text(city)
                    .font(.system(size: 13.5, weight: .bold, design: .rounded))
                    .foregroundStyle(JYLTheme.textPrimary)
                    .lineLimit(1)

                Text(WMOCodeHelper.description(for: snapshot.weatherCode, isChinese: loc.isChinese))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(JYLTheme.textSecondary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                refreshButton
            }

            Spacer(minLength: 0)

            // Hero Section
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: weather.currentSymbolName)
                    .font(.system(size: 30, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(weatherSymbolColor(for: snapshot.weatherCode, isDaytime: snapshot.isDaytime))
                    .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 1.5) {
                    Text(weather.temperatureUnit.format(celsius: snapshot.temperature))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(JYLTheme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    Text("↑ \(weather.temperatureUnit.format(celsius: snapshot.highTemperature))  ↓ \(weather.temperatureUnit.format(celsius: snapshot.lowTemperature))")
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(JYLTheme.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.08))
                        )
                }
            }

            Spacer(minLength: 0)

            // Metrics Row
            HStack(spacing: 6) {
                metricChip(
                    label: L10n.tr(.weatherApparent),
                    value: weather.temperatureUnit.format(celsius: snapshot.apparentTemperature)
                )
                metricChip(
                    label: L10n.tr(.weatherHumidity),
                    value: "\(snapshot.humidity)%"
                )
            }

            Spacer(minLength: 0)

            // Footer
            HStack(spacing: 5) {
                Text(formatUpdateTime(snapshot.lastUpdated))
                    .font(.system(size: 9.5, weight: .regular, design: .rounded))
                    .foregroundStyle(JYLTheme.textMuted)

                if let error = weather.lastError {
                    Circle()
                        .fill(JYLTheme.warning)
                        .frame(width: 5, height: 5)
                        .help("更新告警: \(error)")
                }

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 220)
        .frame(maxHeight: .infinity)
        .jylCard(cornerRadius: 13)
    }

    // MARK: - Refresh Button

    private var refreshButton: some View {
        Button {
            weather.refresh()
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(isHoveringRefresh ? JYLTheme.textPrimary : JYLTheme.textSecondary)
                .rotationEffect(.degrees(isAnimatingRefresh ? 360 : 0))
                .animation(
                    weather.isLoading
                        ? .linear(duration: 1.0).repeatForever(autoreverses: false)
                        : .default,
                    value: isAnimatingRefresh
                )
                .frame(width: 22, height: 22)
                .background(
                    Circle()
                        .fill(isHoveringRefresh ? Color.white.opacity(0.12) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .disabled(weather.isLoading)
        .contentShape(Circle())
        .accessibilityLabel(L10n.tr(.weatherRefresh))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHoveringRefresh = hovering
            }
        }
        .onChange(of: weather.isLoading) { loading in
            isAnimatingRefresh = loading
        }
        .onAppear {
            isAnimatingRefresh = weather.isLoading
        }
    }

    // MARK: - Right Card: Hourly Forecast

    private func rightHourlyCard(snapshot: WeatherSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack(alignment: .center) {
                Text(L10n.tr(.weatherHourly))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(JYLTheme.textPrimary)

                Spacer()

                let high = weather.temperatureUnit.format(celsius: snapshot.highTemperature)
                let low = weather.temperatureUnit.format(celsius: snapshot.lowTemperature)
                Text(loc.isChinese ? "最高 \(high) · 最低 \(low)" : "H: \(high) · L: \(low)")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(JYLTheme.textSecondary)
            }

            Spacer(minLength: 0)

            // Content Carousel
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(Array(snapshot.hourlyForecast.enumerated()), id: \.element.id) { index, item in
                        hourlyColumn(item: item, isFirst: index == 0)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .jylCard(cornerRadius: 13)
    }

    // MARK: - Hourly Item Column

    private func hourlyColumn(item: HourlyForecastItem, isFirst: Bool) -> some View {
        let isDay = isDaytime(for: item.time)
        let symbolName = WMOCodeHelper.symbolName(for: item.weatherCode, isDaytime: isDay)
        let color = weatherSymbolColor(for: item.weatherCode, isDaytime: isDay)

        return VStack(spacing: 6) {
            Text(isFirst ? L10n.tr(.weatherNow) : Self.timeFormatter.string(from: item.time))
                .font(.system(size: 11, weight: isFirst ? .bold : .medium, design: .rounded))
                .foregroundStyle(isFirst ? JYLTheme.primary : JYLTheme.textSecondary)
                .lineLimit(1)

            Image(systemName: symbolName)
                .font(.system(size: 20, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(color)
                .frame(height: 22)

            Text(weather.temperatureUnit.format(celsius: item.temperature))
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .foregroundStyle(JYLTheme.textPrimary)
                .lineLimit(1)

            if item.precipitationProbability > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "drop.fill")
                        .font(.system(size: 8, weight: .semibold))
                    Text("\(item.precipitationProbability)%")
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                }
                .foregroundStyle(Color.cyan)
                .frame(height: 14)
            } else {
                Color.clear
                    .frame(height: 14)
            }
        }
        .frame(minWidth: 42)
    }

    // MARK: - Helper Views & Methods

    private func metricChip(label: String, value: String) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(JYLTheme.textSecondary)
            Text(value)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(JYLTheme.textPrimary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
                )
        )
    }

    private func formatUpdateTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 {
            return L10n.tr(.weatherJustUpdated)
        }
        return L10n.tr(.weatherUpdatedAt, Self.timeFormatter.string(from: date))
    }

    private func isDaytime(for date: Date) -> Bool {
        let hour = Calendar.current.component(.hour, from: date)
        return hour >= 6 && hour < 18
    }

    private func weatherSymbolColor(for code: Int, isDaytime: Bool) -> Color {
        switch code {
        case 0:
            return isDaytime ? JYLTheme.primary : Color(hex: "#818cf8")
        case 1, 2:
            return isDaytime ? JYLTheme.primaryLight : Color(hex: "#93c5fd")
        case 3:
            return JYLTheme.neutral400
        case 45, 48:
            return JYLTheme.neutral500
        case 51...67, 80...82:
            return Color(hex: "#38bdf8")
        case 71...77, 85, 86:
            return Color(hex: "#a5f3fc")
        case 95...99:
            return JYLTheme.primary
        default:
            return JYLTheme.primary
        }
    }
}
