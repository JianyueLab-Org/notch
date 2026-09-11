//
//  WeatherController.swift
//  NotchNotch
//
//  Central domain manager coordinating location resolution, weather data fetching,
//  caching, periodic timers, and UserDefaults persistence.
//

import AppKit
import Combine
import Foundation

@MainActor
public final class WeatherController: ObservableObject {
    public static let shared = WeatherController()

    // MARK: - Constants & UserDefaults Keys

    public enum Keys {
        public static let weatherEnabled = "co.jianyuelab.NotchNotch.weatherEnabled"
        public static let weatherShowInEars = "co.jianyuelab.NotchNotch.weatherShowInEars"
        public static let weatherLocationMode = "co.jianyuelab.NotchNotch.weatherLocationMode"
        public static let weatherCustomCity = "co.jianyuelab.NotchNotch.weatherCustomCity"
        public static let weatherTemperatureUnit = "co.jianyuelab.NotchNotch.weatherTemperatureUnit"
        public static let weatherRefreshInterval = "co.jianyuelab.NotchNotch.weatherRefreshInterval"
        public static let weatherCachedSnapshot = "co.jianyuelab.NotchNotch.weatherCachedSnapshot"
        public static let weatherCachedLocation = "co.jianyuelab.NotchNotch.weatherCachedLocation"
    }

    public static let weatherEnabledKey = Keys.weatherEnabled
    public static let weatherShowInEarsKey = Keys.weatherShowInEars
    public static let weatherLocationModeKey = Keys.weatherLocationMode
    public static let weatherCustomCityKey = Keys.weatherCustomCity
    public static let weatherTemperatureUnitKey = Keys.weatherTemperatureUnit
    public static let weatherRefreshIntervalKey = Keys.weatherRefreshInterval
    public static let weatherCachedSnapshotKey = Keys.weatherCachedSnapshot
    public static let weatherCachedLocationKey = Keys.weatherCachedLocation

    public static let refreshIntervalOptions: [Int] = [15, 30, 60]
    public static let defaultRefreshInterval: Int = 30

    // MARK: - Published State

    @Published public private(set) var currentSnapshot: WeatherSnapshot?
    @Published public private(set) var currentLocation: ResolvedLocation?
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var lastError: String? = nil

    @Published public var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Keys.weatherEnabled)
            if isEnabled {
                if isStarted {
                    startTimer()
                    refresh()
                }
            } else {
                stopTimer()
                currentRefreshTask?.cancel()
                currentRefreshTask = nil
                isLoading = false
            }
        }
    }

    @Published public var showInEars: Bool {
        didSet {
            defaults.set(showInEars, forKey: Keys.weatherShowInEars)
        }
    }

    @Published public var locationMode: LocationMode {
        didSet {
            guard locationMode != oldValue else { return }
            defaults.set(locationMode.rawValue, forKey: Keys.weatherLocationMode)
            if isEnabled {
                refresh()
            }
        }
    }

    @Published public var customCity: String {
        didSet {
            defaults.set(customCity, forKey: Keys.weatherCustomCity)
        }
    }

    @Published public var temperatureUnit: TemperatureUnit {
        didSet {
            defaults.set(temperatureUnit.rawValue, forKey: Keys.weatherTemperatureUnit)
        }
    }

    @Published public var refreshIntervalMinutes: Int {
        didSet {
            defaults.set(refreshIntervalMinutes, forKey: Keys.weatherRefreshInterval)
            if isStarted && isEnabled {
                startTimer()
            }
        }
    }

    // MARK: - Computed Properties

    public var formattedCurrentTemperature: String? {
        guard let snapshot = currentSnapshot else { return nil }
        return temperatureUnit.format(celsius: snapshot.temperature)
    }

    public var currentSymbolName: String {
        guard let snapshot = currentSnapshot else { return "cloud.sun.fill" }
        return WMOCodeHelper.symbolName(for: snapshot.weatherCode, isDaytime: snapshot.isDaytime)
    }

    public var currentConditionDescription: String {
        guard let snapshot = currentSnapshot else { return "暂无天气信息" }
        return WMOCodeHelper.description(for: snapshot.weatherCode)
    }

    // MARK: - Private Properties

    private let locationService: LocationService
    private let weatherService: WeatherService
    private let defaults: UserDefaults

    private var timerCancellable: AnyCancellable?
    private var wakeCancellable: AnyCancellable?
    private(set) var isStarted: Bool = false
    private var currentRefreshTask: Task<Void, Never>?

    // MARK: - Initialization

    public init(
        locationService: LocationService = .shared,
        weatherService: WeatherService = .shared,
        defaults: UserDefaults = .standard
    ) {
        self.locationService = locationService
        self.weatherService = weatherService
        self.defaults = defaults

        if let val = defaults.object(forKey: Keys.weatherEnabled) as? Bool {
            self.isEnabled = val
        } else {
            self.isEnabled = true
        }

        if let val = defaults.object(forKey: Keys.weatherShowInEars) as? Bool {
            self.showInEars = val
        } else {
            self.showInEars = true
        }

        if let raw = defaults.string(forKey: Keys.weatherLocationMode),
           let mode = LocationMode(rawValue: raw) {
            self.locationMode = mode
        } else {
            self.locationMode = .auto
        }

        self.customCity = defaults.string(forKey: Keys.weatherCustomCity) ?? ""

        if let raw = defaults.string(forKey: Keys.weatherTemperatureUnit),
           let unit = TemperatureUnit(rawValue: raw) {
            self.temperatureUnit = unit
        } else {
            self.temperatureUnit = .celsius
        }

        let savedInterval = defaults.integer(forKey: Keys.weatherRefreshInterval)
        self.refreshIntervalMinutes = savedInterval > 0 ? savedInterval : Self.defaultRefreshInterval

        if let snapshotData = defaults.data(forKey: Keys.weatherCachedSnapshot) {
            self.currentSnapshot = try? JSONDecoder().decode(WeatherSnapshot.self, from: snapshotData)
        } else {
            self.currentSnapshot = nil
        }

        if let locationData = defaults.data(forKey: Keys.weatherCachedLocation) {
            self.currentLocation = try? JSONDecoder().decode(ResolvedLocation.self, from: locationData)
        } else {
            self.currentLocation = nil
        }
    }

    // MARK: - Lifecycle

    public func start() {
        guard !isStarted else { return }
        isStarted = true
        registerWakeObserver()
        guard isEnabled else { return }
        startTimer()
        refresh()
    }

    public func stop() {
        isStarted = false
        stopTimer()
        unregisterWakeObserver()
        currentRefreshTask?.cancel()
        currentRefreshTask = nil
        isLoading = false
    }

    // MARK: - Refresh Logic

    public func refresh() {
        _ = refreshTask()
    }

    @discardableResult
    public func refreshTask() -> Task<Void, Never>? {
        guard isEnabled else { return nil }
        if isLoading, let current = currentRefreshTask {
            return current
        }
        guard !isLoading else { return nil }
        isLoading = true
        lastError = nil

        let mode = locationMode
        let city = customCity

        let task = Task { @MainActor [weak self] in
            guard let self = self else { return }
            defer {
                self.isLoading = false
                self.currentRefreshTask = nil
            }

            do {
                let resolved = try await self.locationService.resolveLocation(mode: mode, customCity: city)
                try Task.checkCancellation()
                self.currentLocation = resolved
                if let locData = try? JSONEncoder().encode(resolved) {
                    self.defaults.set(locData, forKey: Keys.weatherCachedLocation)
                }

                let snapshot = try await self.weatherService.fetchWeather(for: resolved)
                try Task.checkCancellation()
                self.currentSnapshot = snapshot
                if let data = try? JSONEncoder().encode(snapshot) {
                    self.defaults.set(data, forKey: Keys.weatherCachedSnapshot)
                }
                self.lastError = nil
            } catch is CancellationError {
                // Task was cancelled, leave state untouched
            } catch {
                self.lastError = error.localizedDescription
            }
        }

        self.currentRefreshTask = task
        return task
    }

    public func refreshAndWait() async {
        if let task = refreshTask() {
            await task.value
        }
    }

    // MARK: - Mutation Methods

    public func setEnabled(_ enabled: Bool) {
        guard self.isEnabled != enabled else { return }
        self.isEnabled = enabled
    }

    public func setShowInEars(_ show: Bool) {
        guard self.showInEars != show else { return }
        self.showInEars = show
    }

    public func setLocationMode(_ mode: LocationMode) {
        guard self.locationMode != mode else { return }
        self.locationMode = mode
    }

    public func setCustomCity(_ city: String) {
        let trimmed = city.trimmingCharacters(in: .whitespacesAndNewlines)
        self.customCity = trimmed
        if isEnabled {
            refresh()
        }
    }

    public func setTemperatureUnit(_ unit: TemperatureUnit) {
        guard self.temperatureUnit != unit else { return }
        self.temperatureUnit = unit
    }

    public func setRefreshInterval(_ minutes: Int) {
        guard self.refreshIntervalMinutes != minutes else { return }
        self.refreshIntervalMinutes = minutes
    }

    // MARK: - Internal / Testing Helpers

    internal func checkAndRefreshIfNeeded() {
        guard isEnabled, !isLoading else { return }
        if let lastUpdated = currentSnapshot?.lastUpdated {
            let intervalSeconds = Double(refreshIntervalMinutes) * 60.0
            if Date().timeIntervalSince(lastUpdated) >= intervalSeconds {
                refresh()
            }
        } else {
            refresh()
        }
    }

    internal func setSnapshotForTesting(_ snapshot: WeatherSnapshot?) {
        self.currentSnapshot = snapshot
    }

    internal func setLocationForTesting(_ location: ResolvedLocation?) {
        self.currentLocation = location
    }

    internal func setErrorForTesting(_ error: String?) {
        self.lastError = error
    }

    // MARK: - Private Helpers

    private func startTimer() {
        stopTimer()
        timerCancellable = Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.checkAndRefreshIfNeeded()
                }
            }
    }

    private func stopTimer() {
        timerCancellable?.cancel()
        timerCancellable = nil
    }

    private func registerWakeObserver() {
        unregisterWakeObserver()
        wakeCancellable = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self = self, self.isEnabled else { return }
                    self.refresh()
                }
            }
    }

    private func unregisterWakeObserver() {
        wakeCancellable?.cancel()
        wakeCancellable = nil
    }
}
