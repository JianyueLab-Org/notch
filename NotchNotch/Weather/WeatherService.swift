//
//  WeatherService.swift
//  NotchNotch
//
//  Open-Meteo REST API client for fetching current and hourly weather forecasts.
//

import Foundation

public enum WeatherServiceError: LocalizedError, Sendable, Equatable {
    case invalidURL
    case invalidResponse(statusCode: Int)
    case decodingError(String)
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "无效的天气请求地址"
        case .invalidResponse(let statusCode):
            return "天气服务响应异常（状态码：\(statusCode)）"
        case .decodingError(let details):
            return "解析天气数据失败：\(details)"
        case .networkError(let details):
            return "网络请求失败：\(details)"
        }
    }
}

public final class WeatherService: Sendable {
    public static let shared = WeatherService()

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Fetches current weather and hourly forecast for the given resolved location.
    public func fetchWeather(for location: ResolvedLocation) async throws -> WeatherSnapshot {
        let urlString = "https://api.open-meteo.com/v1/forecast?latitude=\(location.latitude)&longitude=\(location.longitude)&current=temperature_2m,relative_humidity_2m,apparent_temperature,is_day,weather_code&hourly=temperature_2m,weather_code,precipitation_probability&daily=temperature_2m_max,temperature_2m_min&timezone=auto&forecast_days=2"

        guard let url = URL(string: urlString) else {
            throw WeatherServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10.0
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw WeatherServiceError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WeatherServiceError.networkError("未能获取有效的 HTTP 响应")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw WeatherServiceError.invalidResponse(statusCode: httpResponse.statusCode)
        }

        let dto: ForecastResponseDTO
        do {
            dto = try JSONDecoder().decode(ForecastResponseDTO.self, from: data)
        } catch {
            throw WeatherServiceError.decodingError(error.localizedDescription)
        }

        return transform(dto: dto, location: location)
    }

    // MARK: - Private Helpers

    private func transform(dto: ForecastResponseDTO, location: ResolvedLocation) -> WeatherSnapshot {
        let current = dto.current
        let highTemp = dto.daily.temperature_2m_max.first ?? current.temperature_2m
        let lowTemp = dto.daily.temperature_2m_min.first ?? current.temperature_2m

        let locationTimeZone: TimeZone? = {
            if let offset = dto.utc_offset_seconds {
                return TimeZone(secondsFromGMT: offset)
            }
            if let tzName = dto.timezone {
                return TimeZone(identifier: tzName)
            }
            return nil
        }()

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        if let locationTimeZone = locationTimeZone {
            dateFormatter.timeZone = locationTimeZone
        }

        let now = Date()
        let threshold = now.addingTimeInterval(-1800)

        var hourlyItems: [HourlyForecastItem] = []
        let hourlyCount = min(
            dto.hourly.time.count,
            dto.hourly.temperature_2m.count,
            dto.hourly.weather_code.count
        )

        for i in 0..<hourlyCount {
            let timeStr = dto.hourly.time[i]
            guard let date = parseDate(timeStr, formatter: dateFormatter, timeZone: locationTimeZone) else {
                continue
            }
            let temp = dto.hourly.temperature_2m[i]
            let code = dto.hourly.weather_code[i]
            let precip: Int = {
                if let probs = dto.hourly.precipitation_probability, i < probs.count, let p = probs[i] {
                    return p
                }
                return 0
            }()

            hourlyItems.append(HourlyForecastItem(
                time: date,
                temperature: temp,
                weatherCode: code,
                precipitationProbability: precip
            ))
        }

        let futureHourly = hourlyItems.filter { $0.time >= threshold }
        let selectedHourly = futureHourly.isEmpty ? Array(hourlyItems.prefix(8)) : Array(futureHourly.prefix(8))

        return WeatherSnapshot(
            temperature: current.temperature_2m,
            apparentTemperature: current.apparent_temperature,
            weatherCode: current.weather_code,
            humidity: current.relative_humidity_2m,
            highTemperature: highTemp,
            lowTemperature: lowTemp,
            hourlyForecast: selectedHourly,
            cityName: location.cityName,
            lastUpdated: now,
            isDaytime: current.is_day == 1
        )
    }

    private func parseDate(_ string: String, formatter: DateFormatter, timeZone: TimeZone?) -> Date? {
        if let date = formatter.date(from: string) {
            return date
        }

        let altFormatter = DateFormatter()
        altFormatter.locale = Locale(identifier: "en_US_POSIX")
        altFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        if let timeZone = timeZone {
            altFormatter.timeZone = timeZone
        }
        if let date = altFormatter.date(from: string) {
            return date
        }

        let isoFormatter = ISO8601DateFormatter()
        if let timeZone = timeZone {
            isoFormatter.timeZone = timeZone
        }
        return isoFormatter.date(from: string)
    }
}

// MARK: - API Decodable Models

private struct ForecastResponseDTO: Decodable {
    let utc_offset_seconds: Int?
    let timezone: String?
    let current: CurrentDTO
    let daily: DailyDTO
    let hourly: HourlyDTO
}

private struct CurrentDTO: Decodable {
    let temperature_2m: Double
    let relative_humidity_2m: Int
    let apparent_temperature: Double
    let is_day: Int
    let weather_code: Int
}

private struct DailyDTO: Decodable {
    let temperature_2m_max: [Double]
    let temperature_2m_min: [Double]
}

private struct HourlyDTO: Decodable {
    let time: [String]
    let temperature_2m: [Double]
    let weather_code: [Int]
    let precipitation_probability: [Int?]?
}
