# Weather Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement real-time weather monitoring in NotchNotch, providing ambient glanceable temperature and condition icons in the compact notch ears and a full-featured forecast card in the expanded panel.

**Architecture:** A domain subsystem under `NotchNotch/Weather/` with `WeatherModels`, `LocationService` (CoreLocation + IP fallback + Geocoding), `WeatherService` (Open-Meteo API), and `@MainActor WeatherController`. Integrated into `NotchPanelView` (ear capsules & new `.weather` tab), `NotchWindowController` (live activity scheduler), and `SettingsView` (weather preferences tab).

**Tech Stack:** Swift 6, SwiftUI, Combine, URLSession, CoreLocation, Open-Meteo REST API, Xcode 16.

**Spec:** `docs/superpowers/specs/2026-09-11-weather-integration-design.md`

## Global Constraints

- Platform: macOS 13.0+
- Swift version: Swift 6.0 (`PBXFileSystemSynchronizedRootGroup` auto-synchronizes files in `NotchNotch/`)
- Design System: `JYLTheme` design tokens (`JYLTheme.surfaceRaised`, `JYLTheme.primary`, `.jylCard(cornerRadius: 13)`)
- No API Keys: Use Open-Meteo free tier (`api.open-meteo.com` and `geocoding-api.open-meteo.com`)
- Persistence: `UserDefaults.standard` keys under `co.jianyuelab.NotchNotch.weather*`
- Scratch/Test scripts: `<project>/.temp/`, NEVER `/tmp`

---

### Task 1: Weather Models & WMO Mapping

**Files:**
- Create: `NotchNotch/Weather/WeatherModels.swift`
- Test: `.temp/test_weather_models.swift`

**Interfaces:**
- Produces:
  - `struct WeatherSnapshot: Codable, Equatable, Sendable`
  - `struct HourlyForecastItem: Codable, Equatable, Identifiable, Sendable`
  - `enum TemperatureUnit: String, Codable, CaseIterable` (.celsius, .fahrenheit)
  - `enum LocationMode: String, Codable, CaseIterable` (.auto, .manual)
  - `struct WMOCodeHelper`: static methods `symbolName(for:isDaytime:) -> String` and `description(for:) -> String`

- [ ] **Step 1: Create `.temp` test sandbox and write failing model test**

Create `.temp/test_weather_models.swift`:
```swift
import Foundation

// Expectation: Test decoding Open-Meteo JSON into WeatherSnapshot and WMO code mapping
let sampleJson = """
{
  "current": {
    "temperature_2m": 24.5,
    "relative_humidity_2m": 65,
    "apparent_temperature": 26.1,
    "is_day": 1,
    "weather_code": 1
  },
  "daily": {
    "temperature_2m_max": [29.0],
    "temperature_2m_min": [19.5]
  },
  "hourly": {
    "time": ["2026-09-11T10:00", "2026-09-11T11:00"],
    "temperature_2m": [24.5, 25.0],
    "weather_code": [1, 2],
    "precipitation_probability": [0, 10]
  }
}
""".data(using: .utf8)!

print("Running WeatherModels test...")
// Test WMO mappings
assert(WMOCodeHelper.symbolName(for: 0, isDaytime: true) == "sun.max.fill")
assert(WMOCodeHelper.symbolName(for: 0, isDaytime: false) == "moon.stars.fill")
assert(WMOCodeHelper.symbolName(for: 61, isDaytime: true) == "cloud.rain.fill")
assert(WMOCodeHelper.description(for: 0) == "晴朗")
assert(WMOCodeHelper.description(for: 61) == "小雨")
print("WeatherModels test passed successfully!")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift .temp/test_weather_models.swift`
Expected: FAIL with "cannot find 'WMOCodeHelper' in scope"

- [ ] **Step 3: Implement `NotchNotch/Weather/WeatherModels.swift`**

Write `NotchNotch/Weather/WeatherModels.swift` containing:
- `WeatherSnapshot` with `temperature`, `apparentTemperature`, `weatherCode`, `humidity`, `highTemperature`, `lowTemperature`, `hourlyForecast`, `cityName`, `lastUpdated`, `isDaytime`.
- `HourlyForecastItem` with `time`, `temperature`, `weatherCode`, `precipitationProbability`.
- `TemperatureUnit` with formatting helper `format(celsius: Double) -> String`.
- `LocationMode` (.auto, .manual).
- `WMOCodeHelper` with complete mapping for codes 0 through 99 to SF Symbols and Chinese descriptions.

- [ ] **Step 4: Verify test passes with implementation**

Run: `swift -I NotchNotch/Weather .temp/test_weather_models.swift` (or compile with `WeatherModels.swift` concatenated)
Expected: PASS with "WeatherModels test passed successfully!"

- [ ] **Step 5: Verify Xcode build passes**

Run: `xcodebuild -scheme NotchNotch -configuration Debug build`
Expected: BUILD SUCCEEDED

- [ ] **Step 6: Commit**

```bash
git add NotchNotch/Weather/WeatherModels.swift
git commit -m "feat(weather): add weather domain data models and WMO code mapping"
```

---

### Task 2: Multi-Tier Location & Geocoding Service

**Files:**
- Create: `NotchNotch/Weather/LocationService.swift`
- Test: `.temp/test_location_service.swift`

**Interfaces:**
- Consumes: `WeatherModels.LocationMode`
- Produces:
  - `struct ResolvedLocation: Sendable, Equatable`: `latitude: Double`, `longitude: Double`, `cityName: String`
  - `final class LocationService: NSObject, CLLocationManagerDelegate, Sendable`:
    - `func resolveLocation(mode: LocationMode, customCity: String) async throws -> ResolvedLocation`
    - `func geocode(city: String) async throws -> ResolvedLocation`
    - `func fallbackIPLocation() async throws -> ResolvedLocation`

- [ ] **Step 1: Write test for Geocoding and IP Geolocation fallback**

Create `.temp/test_location_service.swift`:
```swift
import Foundation

@main
struct TestLocation {
    static func main() async {
        print("Testing IP fallback location...")
        let service = LocationService()
        do {
            let loc = try await service.fallbackIPLocation()
            print("Resolved IP location: \(loc.cityName), lat=\(loc.latitude), lon=\(loc.longitude)")
            assert(!loc.cityName.isEmpty)
            assert(loc.latitude != 0)
        } catch {
            print("IP location error (tolerated in sandbox if offline): \(error)")
        }
    }
}
```

- [ ] **Step 2: Implement `NotchNotch/Weather/LocationService.swift`**

Implement:
- `CLLocationManager` wrapper for system location if authorized.
- Geocoding API via Open-Meteo (`https://geocoding-api.open-meteo.com/v1/search?name=...&count=1&language=zh&format=json`).
- IP Geolocation fallback via `https://ip-api.com/json/?fields=status,city,regionName,lat,lon` with timeout.
- Unified `resolveLocation(mode: LocationMode, customCity: String)` method handling fallback gracefully.

- [ ] **Step 3: Run test to verify functionality**

Run: `swift NotchNotch/Weather/WeatherModels.swift NotchNotch/Weather/LocationService.swift .temp/test_location_service.swift`
Expected: Prints resolved location and completes.

- [ ] **Step 4: Verify Xcode project compiles**

Run: `xcodebuild -scheme NotchNotch -configuration Debug build`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add NotchNotch/Weather/LocationService.swift
git commit -m "feat(weather): add LocationService with GPS, geocoding and IP fallback"
```

---

### Task 3: Open-Meteo Weather API Client

**Files:**
- Create: `NotchNotch/Weather/WeatherService.swift`
- Test: `.temp/test_weather_service.swift`

**Interfaces:**
- Consumes: `WeatherSnapshot`, `ResolvedLocation`
- Produces:
  - `final class WeatherService: Sendable`:
    - `func fetchWeather(for location: ResolvedLocation) async throws -> WeatherSnapshot`

- [ ] **Step 1: Write test for Open-Meteo weather fetching**

Create `.temp/test_weather_service.swift`:
```swift
import Foundation

@main
struct TestWeatherService {
    static func main() async throws {
        print("Testing WeatherService fetch...")
        let service = WeatherService()
        let location = ResolvedLocation(latitude: 31.2304, longitude: 121.4737, cityName: "Shanghai")
        let snapshot = try await service.fetchWeather(for: location)
        print("Fetched snapshot: temp=\(snapshot.temperature)°C, desc=\(WMOCodeHelper.description(for: snapshot.weatherCode)), hourlyCount=\(snapshot.hourlyForecast.count)")
        assert(snapshot.hourlyForecast.count > 0)
        assert(snapshot.cityName == "Shanghai")
        print("WeatherService test passed!")
    }
}
```

- [ ] **Step 2: Implement `NotchNotch/Weather/WeatherService.swift`**

Implement:
- Request URL construction for `https://api.open-meteo.com/v1/forecast` querying current, hourly (24h), daily max/min, timezone=auto.
- Decodable DTO structures mapping the raw Open-Meteo JSON.
- Transform raw response into domain `WeatherSnapshot` with next 8 hourly intervals.
- Proper HTTP response validation (200 OK) and error handling.

- [ ] **Step 3: Run test script to verify actual API response parsing**

Run: `swift NotchNotch/Weather/WeatherModels.swift NotchNotch/Weather/LocationService.swift NotchNotch/Weather/WeatherService.swift .temp/test_weather_service.swift`
Expected: Fetches real weather and outputs "WeatherService test passed!"

- [ ] **Step 4: Verify Xcode build**

Run: `xcodebuild -scheme NotchNotch -configuration Debug build`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add NotchNotch/Weather/WeatherService.swift
git commit -m "feat(weather): add WeatherService for Open-Meteo API fetching"
```

---

### Task 4: Weather Domain Controller & Cache Manager

**Files:**
- Create: `NotchNotch/Weather/WeatherController.swift`
- Test: Build verification & cache persistence test

**Interfaces:**
- Consumes: `WeatherModels`, `LocationService`, `WeatherService`
- Produces:
  - `@MainActor final class WeatherController: ObservableObject`:
    - `static let shared = WeatherController()`
    - `@Published public private(set) var currentSnapshot: WeatherSnapshot?`
    - `@Published public private(set) var isLoading: Bool`
    - `@Published public private(set) var lastError: String?`
    - `@Published public var isEnabled: Bool`
    - `@Published public var showInEars: Bool`
    - `@Published public var locationMode: LocationMode`
    - `@Published public var customCity: String`
    - `@Published public var temperatureUnit: TemperatureUnit`
    - `@Published public var refreshIntervalMinutes: Int`
    - `func start()`
    - `func refresh()`
    - `func setEnabled(_ enabled: Bool)`
    - `func setShowInEars(_ show: Bool)`
    - `func setLocationMode(_ mode: LocationMode)`
    - `func setCustomCity(_ city: String)`
    - `func setTemperatureUnit(_ unit: TemperatureUnit)`
    - `func setRefreshInterval(_ minutes: Int)`

- [ ] **Step 1: Implement `NotchNotch/Weather/WeatherController.swift`**

Implement:
- Read defaults on init from `UserDefaults.standard` with `co.jianyuelab.NotchNotch.weather*` keys.
- Load cached snapshot from `co.jianyuelab.NotchNotch.weatherCachedSnapshot` on initialization.
- Periodic timer (via `Timer.publish` / Task) checking elapsed time against `refreshIntervalMinutes`.
- Observe `NSWorkspace.didWakeNotification` to trigger background refresh on wake.
- Implement `refresh()` async method to resolve location -> fetch weather -> cache snapshot -> update `@Published` state.

- [ ] **Step 2: Verify compilation with Xcode**

Run: `xcodebuild -scheme NotchNotch -configuration Debug build`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add NotchNotch/Weather/WeatherController.swift
git commit -m "feat(weather): add WeatherController domain manager with caching and timers"
```

---

### Task 5: Weather Card View for Expanded Notch Panel

**Files:**
- Create: `NotchNotch/Views/WeatherCardView.swift`

**Interfaces:**
- Consumes: `WeatherController.shared`, `WeatherSnapshot`, `JYLTheme`
- Produces:
  - `struct WeatherCardView: View`

- [ ] **Step 1: Implement `WeatherCardView.swift`**

Implement:
- Dual-zone layout inside `.jylCard(cornerRadius: 13)`:
  - **Left Section (~220pt)**:
    - City name + condition title (`上海 · 多云`), refresh button (spins when `weather.isLoading`).
    - Large temperature text (48pt, bold rounded, e.g. `24°`) with high/low `↑ 28°  ↓ 19°`.
    - Subtle metrics row: `体感 26°` · `湿度 65%` · `降水 10%`.
    - Last updated timestamp / offline indicator.
  - **Right Section (remaining width, ~360pt)**:
    - Horizontal scroll view of hourly forecast items.
    - Each item has: time (e.g. `12:00`), weather SF symbol icon, forecast temperature, and blue raindrop + probability if > 15%.
  - Empty/Loading state placeholder when snapshot is not yet loaded.

- [ ] **Step 2: Verify Xcode build**

Run: `xcodebuild -scheme NotchNotch -configuration Debug build`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add NotchNotch/Views/WeatherCardView.swift
git commit -m "feat(weather): add WeatherCardView component for expanded notch panel"
```

---

### Task 6: Notch Overlay & Live Activity Integration

**Files:**
- Modify: `NotchNotch/Views/NotchPanelView.swift`
- Modify: `NotchNotch/Notch/NotchWindowController.swift`

**Interfaces:**
- Consumes: `WeatherController.shared`, `WeatherCardView`
- Modifies:
  - `NotchActiveTab`: add case `weather = "Weather"`
  - `NotchPanelView.topBar`: add Weather tab icon `circleIconButton(tab: .weather, icon: "cloud.sun.fill")`
  - `NotchPanelView.compactLeftEar`: render weather symbol when idle
  - `NotchPanelView.compactRightEar`: render temperature pill when idle
  - `NotchWindowController`: observe `WeatherController.shared.$currentSnapshot` & `$isEnabled` to update `hasLiveActivity`

- [ ] **Step 1: Update `NotchActiveTab` and tab navigation in `NotchPanelView.swift`**

Add `case weather = "Weather"` to `NotchActiveTab`.
In `topBar`:
Add weather button between Overview and Shelf.
In main `ZStack` body:
Add `WeatherCardView()` with `.opacity(activeTab == .weather ? 1 : 0)`.

- [ ] **Step 2: Update compact ears in `NotchPanelView.swift`**

In `compactLeftEar`:
When `nowPlaying.hasActiveTrack == false` and `agent.activeAlert == nil` and `weather.isEnabled && weather.showInEars`:
Render weather icon with soft tint.
In `compactRightEar`:
When idle, render formatted temperature text pill (e.g. `24°`).

- [ ] **Step 3: Wire `NotchWindowController.swift` live activity updates**

In `NotchWindowController.observeLiveActivities()`:
Include `WeatherController.shared.$currentSnapshot` and `WeatherController.shared.$isEnabled` in `updateHasLiveActivity()`.
Call `WeatherController.shared.start()` in `NotchWindowController.start()`.

- [ ] **Step 4: Verify Xcode build**

Run: `xcodebuild -scheme NotchNotch -configuration Debug build`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add NotchNotch/Views/NotchPanelView.swift NotchNotch/Notch/NotchWindowController.swift
git commit -m "feat(weather): integrate weather tab and compact ear live activities into notch overlay"
```

---

### Task 7: Settings View Integration

**Files:**
- Modify: `NotchNotch/Views/SettingsView.swift`

**Interfaces:**
- Consumes: `WeatherController.shared`
- Modifies:
  - `SettingsTab`: add case `weather = "天气"`
  - `SettingsView`: render `weatherSection` with master toggle, ear toggle, location mode picker, custom city input, unit selector, and refresh button.

- [ ] **Step 1: Add `SettingsTab.weather` in `SettingsView.swift`**

Add `case weather = "天气"` with SF Symbol `cloud.sun.fill`.

- [ ] **Step 2: Implement `weatherSection` in `SettingsView.swift`**

Add cards:
- **基础开关**: Enable Weather toggle, Show in notch ears toggle.
- **位置设置**: Location mode picker (`自动定位` vs `指定城市`), custom city textfield with submit button.
- **显示与刷新**: Temperature unit picker (`摄氏度 (°C)` vs `华氏度 (°F)`), refresh interval picker.
- **状态与操作**: Resolved location details, last updated date, "立即刷新数据" button.

- [ ] **Step 3: Verify Xcode build**

Run: `xcodebuild -scheme NotchNotch -configuration Debug build`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add NotchNotch/Views/SettingsView.swift
git commit -m "feat(weather): add weather preferences tab to settings window"
```

---

### Task 8: End-to-End Verification & Cleanup

**Files:**
- Delete: `.temp/` scratch scripts

- [ ] **Step 1: Clean and build Release application**

Run: `xcodebuild -scheme NotchNotch -configuration Release build`
Expected: BUILD SUCCEEDED

- [ ] **Step 2: Clean up temporary test files in `.temp/`**

Remove `.temp/` directory per user rule ("Scratch files in <project>/.temp/ - delete when the task is done").

- [ ] **Step 3: Commit and verify git status**

```bash
git status
```
Verify clean workspace with all changes committed.
