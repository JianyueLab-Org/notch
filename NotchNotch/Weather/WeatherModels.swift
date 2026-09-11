//
//  WeatherModels.swift
//  NotchNotch
//
//  Domain models and WMO weather code mapping for weather integration.
//

import Foundation

public enum TemperatureUnit: String, Codable, CaseIterable, Identifiable, Sendable {
    case celsius = "celsius"
    case fahrenheit = "fahrenheit"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .celsius:
            return "摄氏度 (°C)"
        case .fahrenheit:
            return "华氏度 (°F)"
        }
    }

    public func format(celsius: Double) -> String {
        switch self {
        case .celsius:
            return "\(Int(round(celsius)))°"
        case .fahrenheit:
            return "\(Int(round(celsius * 9.0 / 5.0 + 32.0)))°"
        }
    }
}

public enum LocationMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto = "auto"
    case manual = "manual"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto:
            return "自动定位"
        case .manual:
            return "指定城市"
        }
    }
}

public struct HourlyForecastItem: Codable, Equatable, Identifiable, Sendable {
    public var id: Date { time }
    public let time: Date
    public let temperature: Double
    public let weatherCode: Int
    public let precipitationProbability: Int

    public init(
        time: Date,
        temperature: Double,
        weatherCode: Int,
        precipitationProbability: Int
    ) {
        self.time = time
        self.temperature = temperature
        self.weatherCode = weatherCode
        self.precipitationProbability = precipitationProbability
    }
}

public struct WeatherSnapshot: Codable, Equatable, Sendable {
    public let temperature: Double
    public let apparentTemperature: Double
    public let weatherCode: Int
    public let humidity: Int
    public let highTemperature: Double
    public let lowTemperature: Double
    public let hourlyForecast: [HourlyForecastItem]
    public let cityName: String
    public let lastUpdated: Date
    public let isDaytime: Bool

    public init(
        temperature: Double,
        apparentTemperature: Double,
        weatherCode: Int,
        humidity: Int,
        highTemperature: Double,
        lowTemperature: Double,
        hourlyForecast: [HourlyForecastItem],
        cityName: String,
        lastUpdated: Date,
        isDaytime: Bool
    ) {
        self.temperature = temperature
        self.apparentTemperature = apparentTemperature
        self.weatherCode = weatherCode
        self.humidity = humidity
        self.highTemperature = highTemperature
        self.lowTemperature = lowTemperature
        self.hourlyForecast = hourlyForecast
        self.cityName = cityName
        self.lastUpdated = lastUpdated
        self.isDaytime = isDaytime
    }
}

public enum WMOCodeHelper: Sendable {
    public static func symbolName(for code: Int, isDaytime: Bool = true) -> String {
        switch code {
        case 0:
            return isDaytime ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2:
            return isDaytime ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3:
            return "cloud.fill"
        case 45, 48:
            return "cloud.fog.fill"
        case 51, 53, 55:
            return "cloud.drizzle.fill"
        case 56, 57:
            return "cloud.sleet.fill"
        case 61, 63:
            return "cloud.rain.fill"
        case 65:
            return "cloud.heavyrain.fill"
        case 66, 67:
            return "cloud.sleet.fill"
        case 71, 73, 77:
            return "snowflake"
        case 75, 85, 86:
            return "cloud.snow.fill"
        case 80, 81, 82:
            return isDaytime ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill"
        case 95, 96, 99:
            return "cloud.bolt.rain.fill"
        default:
            return isDaytime ? "sun.max.fill" : "moon.stars.fill"
        }
    }

    public static func description(for code: Int, isChinese: Bool = LocalizationManager.shared.isChinese) -> String {
        if isChinese {
            switch code {
            case 0:
                return "晴朗"
            case 1:
                return "晴间多云"
            case 2:
                return "多云"
            case 3:
                return "阴天"
            case 45, 48:
                return "雾"
            case 51, 53, 55:
                return "毛毛细雨"
            case 56, 57:
                return "冻毛毛雨"
            case 61:
                return "小雨"
            case 63:
                return "中雨"
            case 65:
                return "大雨"
            case 66, 67:
                return "冻雨"
            case 71:
                return "小雪"
            case 73:
                return "中雪"
            case 75:
                return "大雪"
            case 77:
                return "雪粒"
            case 80, 81, 82:
                return "阵雨"
            case 85, 86:
                return "阵雪"
            case 95:
                return "雷阵雨"
            case 96, 99:
                return "雷暴伴有冰雹"
            default:
                return "未知气象"
            }
        } else {
            switch code {
            case 0:
                return "Clear Sky"
            case 1:
                return "Mainly Clear"
            case 2:
                return "Partly Cloudy"
            case 3:
                return "Overcast"
            case 45, 48:
                return "Foggy"
            case 51, 53, 55:
                return "Drizzle"
            case 56, 57:
                return "Freezing Drizzle"
            case 61:
                return "Light Rain"
            case 63:
                return "Moderate Rain"
            case 65:
                return "Heavy Rain"
            case 66, 67:
                return "Freezing Rain"
            case 71:
                return "Light Snow"
            case 73:
                return "Moderate Snow"
            case 75:
                return "Heavy Snow"
            case 77:
                return "Snow Grains"
            case 80, 81, 82:
                return "Rain Showers"
            case 85, 86:
                return "Snow Showers"
            case 95:
                return "Thunderstorm"
            case 96, 99:
                return "Thunderstorm with Hail"
            default:
                return "Unknown"
            }
        }
    }
}
