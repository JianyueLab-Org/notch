# Localization and Language Switching Specification

## Overview

This specification details the architecture and implementation for full-application bilingual localization (Simplified Chinese & English) and dynamic runtime language switching in NotchNotch. Users can switch between "跟随系统 (System Default)", "简体中文 (Simplified Chinese)", and "English" from the Settings window, updating all views across the Notch overlay, cards, HUD, MenuBarExtra, and Settings window immediately without restarting the application.

---

## Goals & Non-Goals

### Goals
- **Full Application Coverage**: Localize all user-facing strings across NotchNotch:
  - Top navigation bar & compact ear badges
  - Weather card, Now Playing card, Schedule timeline card, Drop shelf, Clipboard card
  - HUD bars (volume, brightness, calendar alerts, agent alerts)
  - Settings window (all 5 tabs: General, Weather, Agent, Clipboard, About)
  - MenuBarExtra status bar menu items
  - WMO weather code descriptions (bilingual English / Chinese)
- **Zero-Restart Instant Switching**: Dynamic hot-reloading using SwiftUI reactive state flow (`LocalizationManager.shared`). Switching languages updates all screens in milliseconds.
- **Language Options**:
  - `system`: Follows macOS system preferred language (`Locale.preferredLanguages`), defaulting to Chinese if preferred language starts with `zh`, otherwise English.
  - `zhHans`: Explicit Simplified Chinese.
  - `en`: Explicit English.
- **Type Safety & Key Parity**: Centralized string key registry in `L10n.swift` ensuring compile-time safety and 100% key parity between English and Chinese.
- **Persistence**: Persist user choice in `UserDefaults.standard` under `co.jianyuelab.NotchNotch.appLanguage`.

### Non-Goals
- Adding additional languages beyond Simplified Chinese and English in this phase (YAGNI).
- Complex pluralization catalogs (`.stringsdict`) when straightforward format strings suffice.

---

## Architecture & Subsystems

```
NotchNotch/
└── Localization/
    ├── LocalizationManager.swift  # @MainActor ObservableObject managing active language & locale
    └── L10n.swift                 # Key definitions, bilingual string tables, and formatting helpers
```

### 1. Localization Manager (`LocalizationManager.swift`)

```swift
public enum AppLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case system = "system"
    case zhHans = "zh-Hans"
    case en = "en"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return "跟随系统 (System)"
        case .zhHans: return "简体中文"
        case .en: return "English"
        }
    }
}

@MainActor
public final class LocalizationManager: ObservableObject {
    public static let shared = LocalizationManager()

    @Published public var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: "co.jianyuelab.NotchNotch.appLanguage")
            recomputeActiveCode()
        }
    }

    @Published public private(set) var activeCode: String = "zh-Hans"

    public var isChinese: Bool { activeCode.hasPrefix("zh") }
    public var locale: Locale { Locale(identifier: activeCode) }

    public func setLanguage(_ lang: AppLanguage) {
        self.language = lang
    }
}
```

### 2. String Catalog Engine (`L10n.swift`)

`L10n` provides static accessors and functions:
- `L10n.tr(_ key: L10nKey) -> String`
- `L10n.tr(_ key: L10nKey, _ args: CVarArg...) -> String`

String categories covered in `L10nKey`:
1. **Tabs & Navigation**:
   - `tabOverview`: "概览" / "Overview"
   - `tabWeather`: "天气" / "Weather"
   - `tabShelf`: "暂存架" / "Drop Shelf"
   - `tabClipboard`: "剪贴板" / "Clipboard"
2. **Weather Card**:
   - `weatherHourly`: "逐小时预报" / "Hourly Forecast"
   - `weatherNow`: "现在" / "Now"
   - `weatherApparent`: "体感" / "Feels Like"
   - `weatherHumidity`: "湿度" / "Humidity"
   - `weatherRain`: "降水" / "Rain"
   - `weatherJustUpdated`: "刚刚更新" / "Just updated"
   - `weatherUpdatedAt`: "%@ 更新" / "Updated at %@"
   - `weatherFetching`: "获取天气信息中..." / "Fetching weather data..."
   - `weatherRetry`: "点击重试" / "Retry"
   - `weatherRefresh`: "刷新天气" / "Refresh Weather"
3. **Now Playing Card**:
   - `mediaNotPlaying`: "未在播放媒体" / "Not Playing"
   - `mediaUnknownTrack`: "未知曲目" / "Unknown Track"
   - `mediaUnknownArtist`: "未知艺术家" / "Unknown Artist"
4. **Schedule Timeline Card**:
   - `scheduleNoEvents`: "今日暂无后续日程" / "No upcoming events today"
   - `scheduleInProgress`: "进行中" / "In Progress"
   - `scheduleUpcoming`: "即将开始" / "Upcoming"
   - `scheduleRemaining`: "剩余 %@" / "%@ left"
   - `scheduleElapsed`: "已进行 %@" / "%@ elapsed"
5. **Drop Shelf**:
   - `shelfEmptyTitle`: "拖放文件暂存于此" / "Drag & drop files here"
   - `shelfEmptySubtitle`: "可随时拖拽至其他窗口或终端" / "Ready to drag out to apps or terminal"
   - `shelfClearAll`: "清空暂存架" / "Clear Shelf"
   - `shelfRevealInFinder`: "在访达中显示" / "Reveal in Finder"
   - `shelfAirDrop`: "隔空投送" / "AirDrop"
6. **Clipboard Card**:
   - `clipboardEmptyTitle`: "剪贴板历史为空" / "Clipboard history is empty"
   - `clipboardCopied`: "已复制到剪贴板" / "Copied to clipboard"
   - `clipboardClearAll`: "清除全部记录" / "Clear All History"
7. **Settings Window**:
   - Tabs: `settingsTabGeneral`, `settingsTabWeather`, `settingsTabAgent`, `settingsTabClipboard`, `settingsTabAbout`
   - General: "界面语言", "开机自动启动", "日历日程提醒", etc.
   - Weather: "启用天气服务", "在刘海折叠耳部显示天气", "定位模式与位置", "自动定位", "指定城市", "温度单位", "刷新频率", "立即刷新数据", etc.
   - Agent: "AI 智能体监控", "终端环境配置", etc.
   - Clipboard: "历史保留条数", "清除全部记录", etc.
   - About: "版本", "版权所有", "开源许可证", etc.
8. **MenuBarExtra**:
   - `menuOpenPanel`: "展开刘海面板" / "Open Notch Panel"
   - `menuSettings`: "偏好设置..." / "Settings..."
   - `menuLaunchAtLogin`: "开机自动启动" / "Launch at Login"
   - `menuQuit`: "退出 NotchNotch" / "Quit NotchNotch"

### 3. Weather Condition Localization (`WMOCodeHelper`)
Update `WMOCodeHelper.description(for:isChinese:)`:
- When `isChinese == true`: returns standard Chinese weather condition ("晴朗", "多云", "小雨", etc.).
- When `isChinese == false`: returns standard English weather condition ("Clear Sky", "Partly Cloudy", "Overcast", "Light Rain", "Thunderstorm", etc.).

---

## Settings Integration

In `SettingsView.swift`:
1. Tab Selector:
   - Dynamic tab title: `tab.title(isChinese: loc.isChinese)`
2. General Section:
   - Add new card: **界面语言 (Language)**:
     - Icon: `globe`
     - Description: "选择界面的显示语言，即时生效无需重启应用" / "Select interface language, applied immediately without restarting"
     - Segmented Picker: `AppLanguage.allCases` -> `language.displayName`
     - Changing language immediately triggers SwiftUI redraw across all windows and popups.

---

## Verification Plan

1. **Key Parity Unit Test**:
   - Ensure every `L10nKey` has non-empty definitions in both Chinese and English dictionaries.
2. **Dynamic Switch Verification**:
   - Switch language in Settings -> verify SettingsView updates instantaneously.
   - Expand Notch Panel -> verify Tab buttons and Card labels reflect the chosen language.
   - Switch between Chinese and English -> verify WMO weather codes switch between Chinese and English.
3. **Build Verification**:
   - `xcodebuild -scheme NotchNotch -configuration Release build` succeeds cleanly.
