//
//  LocationService.swift
//  NotchNotch
//
//  Multi-tier location resolution service providing GPS positioning,
//  geocoding, reverse geocoding, and silent IP geolocation fallback.
//

import Foundation
import CoreLocation

public struct ResolvedLocation: Codable, Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let cityName: String

    public init(latitude: Double, longitude: Double, cityName: String) {
        self.latitude = latitude
        self.longitude = longitude
        self.cityName = cityName
    }
}

public enum LocationError: LocalizedError, Sendable, Equatable {
    case cityNotFound(String)
    case locationUnavailable
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .cityNotFound(let city):
            return "未找到城市：\(city)"
        case .locationUnavailable:
            return "无法获取位置信息"
        case .networkError(let message):
            return "网络错误：\(message)"
        }
    }
}

public final class LocationService: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    public static let shared = LocationService()

    private let session: URLSession
    internal var customGPSProvider: (@Sendable () async throws -> CLLocation)?

    public init(
        session: URLSession = .shared,
        customGPSProvider: (@Sendable () async throws -> CLLocation)? = nil
    ) {
        self.session = session
        self.customGPSProvider = customGPSProvider
        super.init()
    }

    /// Resolves location based on the selected mode.
    /// If mode is `.manual`, geocodes the given custom city string.
    /// If mode is `.auto`, attempts CoreLocation GPS resolution and reverse geocoding,
    /// silently falling back to IP geolocation if GPS is denied, unavailable, or times out.
    public func resolveLocation(mode: LocationMode, customCity: String = "") async throws -> ResolvedLocation {
        switch mode {
        case .manual:
            let trimmed = customCity.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return try await fallbackIPLocation()
            }
            return try await geocode(city: trimmed)

        case .auto:
            do {
                return try await requestGPSLocation()
            } catch {
                return try await fallbackIPLocation()
            }
        }
    }

    /// Geocodes a city name into coordinates using Open-Meteo Geocoding API.
    public func geocode(city: String) async throws -> ResolvedLocation {
        guard let encodedCity = city.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://geocoding-api.open-meteo.com/v1/search?name=\(encodedCity)&count=1&language=zh&format=json") else {
            throw LocationError.networkError("Invalid city query: \(city)")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10.0

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LocationError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw LocationError.networkError("Geocoding HTTP status \(statusCode)")
        }

        let decoded: GeocodingResponse
        do {
            decoded = try JSONDecoder().decode(GeocodingResponse.self, from: data)
        } catch {
            throw LocationError.networkError("Failed to decode geocoding response: \(error.localizedDescription)")
        }

        guard let firstResult = decoded.results?.first else {
            throw LocationError.cityNotFound(city)
        }

        return ResolvedLocation(
            latitude: firstResult.latitude,
            longitude: firstResult.longitude,
            cityName: firstResult.name.isEmpty ? city : firstResult.name
        )
    }

    /// Silent IP-based geolocation fallback.
    /// Tries ip-api.com, then secondary fallback ipapi.co, and finally defaults to Shanghai.
    public func fallbackIPLocation() async throws -> ResolvedLocation {
        if let primary = await queryPrimaryIPApi() {
            return primary
        }

        if let secondary = await querySecondaryIPApi() {
            return secondary
        }

        return ResolvedLocation(latitude: 31.2304, longitude: 121.4737, cityName: "上海")
    }

    /// Reverse geocodes coordinates to a readable locality name.
    public func reverseGeocode(latitude: Double, longitude: Double) async -> String {
        let clLocation = CLLocation(latitude: latitude, longitude: longitude)
        let geocoder = CLGeocoder()
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(clLocation)
            if let placemark = placemarks.first {
                if let locality = placemark.locality, !locality.isEmpty {
                    return locality
                }
                if let subAdmin = placemark.subAdministrativeArea, !subAdmin.isEmpty {
                    return subAdmin
                }
                if let admin = placemark.administrativeArea, !admin.isEmpty {
                    return admin
                }
                if let name = placemark.name, !name.isEmpty {
                    return name
                }
            }
        } catch {
            // Silently fallback to "本地"
        }
        return "本地"
    }

    // MARK: - Internal / Private Helpers

    private func requestGPSLocation() async throws -> ResolvedLocation {
        let clLocation: CLLocation
        if let customGPSProvider = customGPSProvider {
            clLocation = try await customGPSProvider()
        } else {
            let fetcher = await GPSLocationFetcher()
            clLocation = try await fetcher.fetchLocation(timeout: 4.0)
        }

        let lat = clLocation.coordinate.latitude
        let lon = clLocation.coordinate.longitude
        let cityName = await reverseGeocode(latitude: lat, longitude: lon)
        return ResolvedLocation(latitude: lat, longitude: lon, cityName: cityName)
    }

    private func queryPrimaryIPApi() async -> ResolvedLocation? {
        guard let url = URL(string: "https://ip-api.com/json/?fields=status,city,regionName,lat,lon") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5.0

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            let decoded = try JSONDecoder().decode(IPApiResponse.self, from: data)
            guard decoded.status == "success",
                  let lat = decoded.lat,
                  let lon = decoded.lon else {
                return nil
            }
            let city = decoded.city ?? decoded.regionName ?? "本地"
            return ResolvedLocation(latitude: lat, longitude: lon, cityName: city)
        } catch {
            return nil
        }
    }

    private func querySecondaryIPApi() async -> ResolvedLocation? {
        guard let url = URL(string: "https://ipapi.co/json/") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5.0
        request.setValue("NotchNotch/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            let decoded = try JSONDecoder().decode(IPApiCoResponse.self, from: data)
            guard let lat = decoded.latitude,
                  let lon = decoded.longitude else {
                return nil
            }
            let city = decoded.city ?? decoded.region ?? "本地"
            return ResolvedLocation(latitude: lat, longitude: lon, cityName: city)
        } catch {
            return nil
        }
    }

    // MARK: - CLLocationManagerDelegate

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Delegate callback available for callers managing an external CLLocationManager
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        // Delegate callback available for callers managing an external CLLocationManager
    }
}

// MARK: - API Decodable Models

private struct GeocodingResponse: Decodable {
    struct ResultItem: Decodable {
        let name: String
        let latitude: Double
        let longitude: Double
        let country: String?
        let admin1: String?
    }
    let results: [ResultItem]?
}

private struct IPApiResponse: Decodable {
    let status: String?
    let city: String?
    let regionName: String?
    let lat: Double?
    let lon: Double?
}

private struct IPApiCoResponse: Decodable {
    let city: String?
    let region: String?
    let latitude: Double?
    let longitude: Double?
}

// MARK: - Single Location Fetcher

@MainActor
private final class GPSLocationFetcher: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, any Error>?
    private var isCompleted = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func fetchLocation(timeout: TimeInterval = 4.0) async throws -> CLLocation {
        guard CLLocationManager.locationServicesEnabled() else {
            throw LocationError.locationUnavailable
        }

        let status = manager.authorizationStatus
        if status == .denied || status == .restricted {
            throw LocationError.locationUnavailable
        }

        return try await withThrowingTaskGroup(of: CLLocation.self) { group in
            group.addTask {
                try await self.requestLocation(status: status)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw LocationError.locationUnavailable
            }

            guard let result = try await group.next() else {
                throw LocationError.locationUnavailable
            }
            group.cancelAll()
            return result
        }
    }

    private func requestLocation(status: CLAuthorizationStatus) async throws -> CLLocation {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CLLocation, any Error>) in
                self.continuation = continuation
                if status == .notDetermined {
                    self.manager.requestWhenInUseAuthorization()
                }
                self.manager.requestLocation()
            }
        } onCancel: {
            Task { @MainActor in
                self.complete(with: .failure(LocationError.locationUnavailable))
            }
        }
    }

    private func complete(with result: Result<CLLocation, any Error>) {
        guard !isCompleted else { return }
        isCompleted = true
        manager.stopUpdatingLocation()
        manager.delegate = nil

        switch result {
        case .success(let loc):
            continuation?.resume(returning: loc)
        case .failure(let err):
            continuation?.resume(throwing: err)
        }
        continuation = nil
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let loc = locations.last {
            complete(with: .success(loc))
        } else {
            complete(with: .failure(LocationError.locationUnavailable))
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        complete(with: .failure(error))
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = self.manager.authorizationStatus
        if status == .denied || status == .restricted {
            complete(with: .failure(LocationError.locationUnavailable))
        } else if status == .authorizedAlways {
            self.manager.requestLocation()
        }
    }
}
