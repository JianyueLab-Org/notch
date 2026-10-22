//
//  LocationService.swift
//  NotchNotch
//
//  Multi-tier location resolution service providing GPS positioning,
//  geocoding, reverse geocoding, and silent IP geolocation fallback.
//

import Foundation
import CoreLocation
import OSLog

public extension Notification.Name {
    /// Posted on the main actor whenever CoreLocation authorization settles into a new
    /// state. Auto mode never blocks on the permission prompt — it asks and falls back to
    /// IP geolocation for that round — so without this nudge the first real GPS fix would
    /// not land until the next refresh tick, up to an hour after the user clicked "Allow".
    static let notchLocationAuthorizationChanged = Notification.Name(
        "co.jianyuelab.NotchNotch.locationAuthorizationChanged"
    )
}

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
    case cityRequired
    case locationUnavailable
    case networkError(String)

    public var errorDescription: String? {
        let code = LocalizationManager.currentLanguageCode()
        switch self {
        case .cityNotFound(let city):
            return L10n.format(key: .locationErrorCityNotFound, languageCode: code, city)
        case .cityRequired:
            return L10n.string(for: .locationErrorCityRequired, languageCode: code)
        case .locationUnavailable:
            return L10n.string(for: .locationErrorUnavailable, languageCode: code)
        case .networkError(let message):
            return L10n.format(key: .locationErrorNetwork, languageCode: code, message)
        }
    }
}

public typealias GPSLocationProviding = @Sendable () async throws -> CLLocation

public final class LocationService: @unchecked Sendable {
    public static let shared = LocationService()

    /// How long to wait for a fix once we *are* authorized. Wi-Fi positioning normally
    /// answers in under a second; anything past this and stale weather beats a stalled
    /// panel, so we let the IP fallback take over.
    private static let gpsFixTimeout: TimeInterval = 8.0

    private let session: URLSession
    private let customGPSProvider: GPSLocationProviding?

    public init(
        session: URLSession = .shared,
        customGPSProvider: GPSLocationProviding? = nil
    ) {
        self.session = session
        self.customGPSProvider = customGPSProvider
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
                throw LocationError.cityRequired
            }
            return try await geocode(city: trimmed)

        case .auto:
            do {
                let resolved = try await requestGPSLocation()
                Log.location.info("Auto location resolved by CoreLocation")
                return resolved
            } catch {
                // A superseded refresh must not go on to burn an IP lookup.
                if error.isCancellation || Task.isCancelled { throw CancellationError() }
                Log.location.info("CoreLocation unavailable, falling back to IP geolocation")
                return try await fallbackIPLocation()
            }
        }
    }

    /// Geocodes a city name into coordinates using Open-Meteo Geocoding API.
    public func geocode(city: String) async throws -> ResolvedLocation {
        let language = LocalizationManager.currentLanguageCode().hasPrefix("zh") ? "zh" : "en"
        guard let encodedCity = city.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://geocoding-api.open-meteo.com/v1/search?name=\(encodedCity)&count=1&language=\(language)&format=json") else {
            throw LocationError.networkError("Invalid city query: \(city)")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10.0

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if error.isCancellation || Task.isCancelled { throw CancellationError() }
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
    /// Tries ipwho.is, then ipapi.co. Throws when both fail.
    public func fallbackIPLocation() async throws -> ResolvedLocation {
        if let primary = await queryPrimaryIPApi() {
            return primary
        }

        try Task.checkCancellation()
        if let secondary = await querySecondaryIPApi() {
            return secondary
        }

        try Task.checkCancellation()
        Log.location.error("Every IP geolocation provider failed")
        throw LocationError.locationUnavailable
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
            // Reverse geocoding failed; the caller still has coordinates.
        }
        return L10n.string(
            for: .locationLocalityUnknown,
            languageCode: LocalizationManager.currentLanguageCode()
        )
    }

    // MARK: - Internal / Private Helpers

    private func requestGPSLocation() async throws -> ResolvedLocation {
        let clLocation: CLLocation
        if let customGPSProvider = customGPSProvider {
            clLocation = try await customGPSProvider()
        } else {
            clLocation = try await GPSLocationProvider.shared.fetchLocation(timeout: Self.gpsFixTimeout)
        }

        let lat = clLocation.coordinate.latitude
        let lon = clLocation.coordinate.longitude
        let cityName = await reverseGeocode(latitude: lat, longitude: lon)
        return ResolvedLocation(latitude: lat, longitude: lon, cityName: cityName)
    }

    /// ipwho.is — keyless, HTTPS, and city-accurate.
    ///
    /// This used to be ip-api.com, which answers 403 to every HTTPS request (their free
    /// tier is cleartext-only, and App Transport Security forbids that), so the primary
    /// provider never once returned a result: auto mode has always been running on the
    /// secondary, whose answers are ISP-registration coarse (a whole prefecture off).
    private func queryPrimaryIPApi() async -> ResolvedLocation? {
        guard let url = URL(string: "https://ipwho.is/") else {
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
            let decoded = try JSONDecoder().decode(IPWhoIsResponse.self, from: data)
            guard decoded.success == true,
                  let lat = decoded.latitude,
                  let lon = decoded.longitude else {
                return nil
            }
            let city = decoded.city ?? decoded.region ?? Self.unknownLocality
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
            let city = decoded.city ?? decoded.region ?? Self.unknownLocality
            return ResolvedLocation(latitude: lat, longitude: lon, cityName: city)
        } catch {
            return nil
        }
    }

    private static var unknownLocality: String {
        L10n.string(for: .locationLocalityUnknown, languageCode: LocalizationManager.currentLanguageCode())
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

private struct IPWhoIsResponse: Decodable {
    let success: Bool?
    let city: String?
    let region: String?
    let latitude: Double?
    let longitude: Double?
}

private struct IPApiCoResponse: Decodable {
    let city: String?
    let region: String?
    let latitude: Double?
    let longitude: Double?
}

// MARK: - Shared GPS Provider

/// The app's one and only `CLLocationManager`.
///
/// It used to be created per request, which is what broke auto mode: on a fresh install
/// the fetcher called `requestWhenInUseAuthorization()` and `requestLocation()` back to
/// back, the still-unauthorized `requestLocation()` failed at once, the fetcher tore its
/// delegate down — and the `locationManagerDidChangeAuthorization` callback that would
/// have retried the moment the user clicked "Allow" arrived at a dead object. Keeping one
/// manager alive for the process lifetime is what makes the grant observable at all.
@MainActor
final class GPSLocationProvider: NSObject, @preconcurrency CLLocationManagerDelegate {
    static let shared = GPSLocationProvider()

    /// A fix this old is still good enough for a city-level weather lookup, and reusing it
    /// spares a round trip to locationd on every refresh tick.
    private static let cachedFixMaxAge: TimeInterval = 10 * 60

    private let manager = CLLocationManager()
    private var waiters: [UUID: CheckedContinuation<CLLocation, any Error>] = [:]
    private var isFixInFlight = false
    private var lastReportedStatus: CLAuthorizationStatus = .notDetermined

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }

    /// macOS has no `.authorizedWhenInUse` — `kCLAuthorizationStatusAuthorizedWhenInUse`
    /// is `API_UNAVAILABLE(macos)`, and the deprecated `.authorized` is a synonym for
    /// `.authorizedAlways` — so this single comparison covers every granted state.
    var isAuthorized: Bool { manager.authorizationStatus == .authorizedAlways }

    var isDenied: Bool {
        let status = manager.authorizationStatus
        return status == .denied || status == .restricted
    }

    override init() {
        super.init()
        manager.delegate = self
        // City-level weather does not need a precise fix, and a coarse one resolves from
        // Wi-Fi alone — no Mac has GPS hardware.
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        lastReportedStatus = manager.authorizationStatus
    }

    func fetchLocation(timeout: TimeInterval) async throws -> CLLocation {
        // `locationServicesEnabled()` talks to locationd and Apple explicitly warns it can
        // block, so keep it off the main actor — a stalled daemon must not freeze the overlay.
        let servicesEnabled = await Task.detached { CLLocationManager.locationServicesEnabled() }.value
        guard servicesEnabled else {
            Log.location.info("Location services are off system-wide")
            throw LocationError.locationUnavailable
        }

        switch manager.authorizationStatus {
        case .notDetermined:
            // The prompt is modal to the *user*, not to us. Waiting on it would stall the
            // weather refresh for as long as they ignore the dialog, so ask and let this
            // round fall back to IP; the authorization callback posts
            // `.notchLocationAuthorizationChanged` and the caller re-resolves immediately.
            Log.location.info("Location authorization undetermined, requesting")
            manager.requestWhenInUseAuthorization()
            throw LocationError.locationUnavailable

        case .denied, .restricted:
            throw LocationError.locationUnavailable

        default:
            break
        }

        if let cached = manager.location,
           abs(cached.timestamp.timeIntervalSinceNow) < Self.cachedFixMaxAge {
            return cached
        }

        return try await requestFix(timeout: timeout)
    }

    private func requestFix(timeout: TimeInterval) async throws -> CLLocation {
        let id = UUID()

        // `requestLocation()` has no timeout of its own and simply never calls back when
        // locationd cannot resolve, so the deadline has to live on our side.
        let timeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            Log.location.info("GPS fix timed out after \(timeout, privacy: .public)s")
            self.finish(id, with: .failure(LocationError.locationUnavailable))
        }
        defer { timeoutTask.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CLLocation, any Error>) in
                waiters[id] = continuation
                // Only one `requestLocation()` may be outstanding at a time, so a second
                // caller joins the first one's fix rather than cancelling it.
                if !isFixInFlight {
                    isFixInFlight = true
                    manager.requestLocation()
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.finish(id, with: .failure(CancellationError()))
            }
        }
    }

    private func finish(_ id: UUID, with result: Result<CLLocation, any Error>) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        if waiters.isEmpty, isFixInFlight {
            isFixInFlight = false
            // `stopUpdatingLocation()` is the documented way to cancel an outstanding
            // `requestLocation()`, so an abandoned fix cannot land on the next caller.
            manager.stopUpdatingLocation()
        }
        continuation.resume(with: result)
    }

    private func finishAll(with result: Result<CLLocation, any Error>) {
        let pending = waiters
        waiters.removeAll()
        isFixInFlight = false
        for continuation in pending.values {
            continuation.resume(with: result)
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            finishAll(with: .failure(LocationError.locationUnavailable))
            return
        }
        Log.location.info("CoreLocation delivered a fix")
        finishAll(with: .success(location))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        Log.location.info("CoreLocation failed: \(error.localizedDescription, privacy: .public)")
        finishAll(with: .failure(error))
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        guard status != lastReportedStatus else { return }
        lastReportedStatus = status
        Log.location.info("Location authorization changed to \(status.rawValue, privacy: .public)")

        if status == .denied || status == .restricted {
            finishAll(with: .failure(LocationError.locationUnavailable))
        }

        NotificationCenter.default.post(name: .notchLocationAuthorizationChanged, object: nil)
    }
}
