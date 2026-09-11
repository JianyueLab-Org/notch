# Weather Display Integration Specification

## Overview

This specification details the end-to-end design for adding real-time weather information to NotchNotch. The feature provides an ambient, glanceable weather capsule in the physical MacBook notch's compact ears during idle states, and a dedicated, rich weather forecast card when the notch panel is expanded.

---

## Goals & Non-Goals

### Goals
- **Ambient Notch Ear Display**: Show weather icon and temperature (e.g. `🌤️ 24°`) in the collapsed notch ears when no higher-priority live activity (Agent interactive alerts, Now Playing media) is active.
- **Dedicated Expanded Weather Tab**: A full card view in the expanded notch panel showing location, condition, current temperature, high/low, apparent temperature, humidity, rain probability, and upcoming 6–8 hourly forecast intervals.
- **Zero-Config Data Retrieval**: Use Open-Meteo free API (no developer API key required).
- **Graceful Multi-Tier Location Fallback**: Prioritize user manual city override, fall back to CoreLocation (system GPS), and further fall back to IP-based geolocation if location permission is not granted.
- **Offline & Battery Conscious**: Cache weather snapshots in `UserDefaults`. Refresh on a 30-minute interval, on system wake, or manual trigger.
- **Dedicated Settings Tab**: Full controls in `SettingsView` for enabling/disabling, ear display toggling, location mode, temperature units (°C / °F), and refresh interval.

### Non-Goals
- Complex multi-city weather tracking or radar maps (YAGNI).
- Apple WeatherKit dependency (requires paid Apple Developer Program signing entitlement).
- Full 15-day extended outlooks (the notch panel dimensions are optimized for immediate day/hourly productivity).

---

## Architecture & Subsystems

```
NotchNotch/
├── Weather/
│   ├── WeatherModels.swift       # WMO weather code mapping, WeatherSnapshot, HourlyForecast
│   ├── LocationService.swift     # CoreLocation manager + IP geolocation fallback + geocoding
│   ├── WeatherService.swift      # Open-Meteo API client with URLSession async/await
│   └── WeatherController.swift   # @MainActor ObservableObject managing state, timers, cache
└── Views/
    ├── WeatherCardView.swift     # SwiftUI card view for expanded panel
    └── SettingsView.swift        # Updated with SettingsTab.weather
```

### 1. Data Models (`WeatherModels.swift`)

```swift
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
}

public struct HourlyForecastItem: Codable, Equatable, Identifiable, Sendable {
    public var id: Date { time }
    public let time: Date
    public let temperature: Double
    public let weatherCode: Int
    public let precipitationProbability: Int
}
```

#### WMO Weather Code to SF Symbols & Descriptions
Open-Meteo provides standard WMO Weather interpretation codes (0–99). `WeatherModels` maps these to SF Symbols and localized Chinese strings:
- `0`: 晴天 / 晴朗 (`sun.max.fill` / `moon.stars.fill`)
- `1, 2, 3`: 晴间多云 / 多云 / 阴天 (`cloud.sun.fill` / `cloud.fill`)
- `45, 48`: 雾 / 浓雾 (`cloud.fog.fill`)
- `51, 53, 55`: 毛毛雨 (`cloud.drizzle.fill`)
- `61, 63, 65`: 小雨 / 中雨 / 大雨 (`cloud.rain.fill` / `cloud.heavyrain.fill`)
- `71, 73, 75, 77`: 小雪 / 大雪 (`snowflake` / `cloud.snow.fill`)
- `80, 81, 82`: 阵雨 (`cloud.sun.rain.fill`)
- `95, 96, 99`: 雷暴 / 强雷阵雨 (`cloud.bolt.rain.fill`)

---

### 2. Location & Geocoding (`LocationService.swift`)

`LocationService` provides coordinates and city labels with three priority tiers:
1. **Manual City Mode**: If set to manual in Settings, query Open-Meteo Geocoding API (`https://geocoding-api.open-meteo.com/v1/search?name={city}&count=1&language=zh&format=json`) to resolve coordinates and standardized city name.
2. **CoreLocation (GPS)**: If auto mode and authorized, request current location via `CLLocationManager.requestLocation()`, and reverse geocode via `CLGeocoder`.
3. **IP Geolocation Fallback**: If system location is not authorized / denied / unavailable, perform a lightweight query to `https://ip-api.com/json/?fields=status,city,regionName,lat,lon` (or `https://ipapi.co/json/`) without blocking or requiring permissions.

---

### 3. Weather Service (`WeatherService.swift`)

- Endpoint:
  `https://api.open-meteo.com/v1/forecast?latitude={lat}&longitude={lon}&current=temperature_2m,relative_humidity_2m,apparent_temperature,is_day,weather_code&hourly=temperature_2m,weather_code,precipitation_probability&daily=temperature_2m_max,temperature_2m_min&timezone=auto&forecast_days=2`
- Handles network latency, timeout (10s), HTTP error codes, and robust JSON decoding.

---

### 4. Domain Controller (`WeatherController.swift`)

`@MainActor final class WeatherController: ObservableObject`:
- `@Published public private(set) var currentSnapshot: WeatherSnapshot?`
- `@Published public private(set) var isLoading: Bool = false`
- `@Published public private(set) var lastError: String? = nil`
- `@Published public var isEnabled: Bool` (from UserDefaults)
- `@Published public var showInEars: Bool` (from UserDefaults)
- `@Published public var locationMode: LocationMode` (.auto / .manual)
- `@Published public var customCity: String`
- `@Published public var temperatureUnit: TemperatureUnit` (.celsius / .fahrenheit)
- `@Published public var refreshIntervalMinutes: Int` (15, 30, 60)

#### Lifecycle & Timers
- On `start()`:
  - Load cached `WeatherSnapshot` from `UserDefaults` immediately (if present).
  - Schedule initial refresh async.
  - Set up 30-minute periodic timer via `Timer.publish`.
  - Listen for `NSWorkspace.didWakeNotification` to refresh when laptop opens.

---

## UI & Integration Design

### 1. Notch Compact Ears & Live Activity Scheduling

#### Scheduling Priority
1. **Agent Alert**: highest urgency (waiting for user input / critical error).
2. **Now Playing**: active media (track playing, scrubber, visualizer).
3. **Schedule Timeline**: imminent meeting reminder (<15 min before start / <10 min before end).
4. **Weather Ambient**: displayed when none of the above are actively demanding the ears and `weatherEnabled && weatherShowInEars`.

#### Compact Appearance in `NotchPanelView`:
- **Left Ear**: Weather SF Symbol (e.g. `sun.max.fill` in amber, `cloud.rain.fill` in light blue).
- **Right Ear**: Temperature pill formatted according to user preference (e.g. `24°` or `75°F`).

### 2. Expanded Notch Panel (`WeatherCardView`)

Dimensions: Matches existing card standards (`HStack(spacing: 10)`, 630pt panel width, masked by `NotchShape`).

#### Left Zone (Current Overview, ~240pt):
- **Header**: City name (`headline`, `JYLTheme.textPrimary`), refresh icon button with subtle rotation animation when `isLoading`.
- **Hero Temperature**: 48pt bold rounded font (e.g. `24°`), weather condition description (e.g. `多云`).
- **High/Low & Apparent**: `↑ 28°  ↓ 19° · 体感 25°`.
- **Metrics Chips**:
  - Humidity: `💧 65%`
  - Rain Probability: `🌧️ 10%`

#### Right Zone (Hourly Forecast, ~360pt):
- Horizontal scrolling strip (`ScrollView(.horizontal, showsIndicators: false)` with `LazyHStack(spacing: 14)`).
- 6 to 8 forecast columns, each containing:
  - Time label: `现在`, `11:00`, `12:00`...
  - SF Symbol weather icon.
  - Forecast temperature.
  - Precipitation badge if rain probability > 15%.

### 3. Settings View Integration (`SettingsView.swift`)

New Tab: `SettingsTab.weather` ("天气", icon `cloud.sun.fill`).
- Section 1: General Toggles (Enable Weather, Show in Notch Ears).
- Section 2: Location Settings (Segmented picker: Auto GPS/IP vs Custom City, with input textfield).
- Section 3: Units & Frequency (Celsius/Fahrenheit, 15m/30m/60m).
- Section 4: Status (Current coordinates, last update timestamp, Manual "立即刷新" button).

---

## UserDefaults Storage Keys

| Key | Type | Default | Purpose |
|---|---|---|---|
| `co.jianyuelab.NotchNotch.weatherEnabled` | `Bool` | `true` | Master toggle |
| `co.jianyuelab.NotchNotch.weatherShowInEars` | `Bool` | `true` | Display in collapsed notch ears |
| `co.jianyuelab.NotchNotch.weatherLocationMode` | `String` | `"auto"` | `"auto"` or `"manual"` |
| `co.jianyuelab.NotchNotch.weatherCustomCity` | `String` | `""` | User specified city name |
| `co.jianyuelab.NotchNotch.weatherTemperatureUnit` | `String` | `"celsius"` | `"celsius"` or `"fahrenheit"` |
| `co.jianyuelab.NotchNotch.weatherRefreshInterval` | `Int` | `30` | Refresh frequency in minutes |
| `co.jianyuelab.NotchNotch.weatherCachedSnapshot` | `Data` | `nil` | Serialized JSON of last valid snapshot |

---

## Error Handling & Resilience

1. **Network Failure / Offline**:
   - Return cached snapshot from `UserDefaults` without erasing state.
   - Display a subtle offline indicator dot next to the update time.
2. **Geocoding / Location Failure**:
   - If manual city not found, set `lastError = "未找到该城市"` and retain previous valid coordinates.
   - If CoreLocation denied, seamlessly query IP fallback without alerting or crashing.
3. **App Transport Security (ATS)**:
   - All APIs (Open-Meteo, geocoding, IP fallback) use HTTPS.
