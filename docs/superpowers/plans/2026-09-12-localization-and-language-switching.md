# Localization and Language Switching Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement comprehensive bilingual localization (Simplified Chinese & English) across NotchNotch, with a dynamic runtime language switcher in Settings allowing users to choose between System Default, 简体中文, and English with instant hot-reload.

**Architecture:** A centralized localization subsystem under `NotchNotch/Localization/` with `LocalizationManager` (managing language state and defaults) and `L10n` (type-safe bilingual string tables). Views observe `LocalizationManager.shared` and retrieve strings via `L10n.tr(_:)`, enabling instant SwiftUI re-renders on language changes without app restarts.

**Tech Stack:** Swift 6, SwiftUI, Combine, AppKit, Xcode 16.

**Spec:** `docs/superpowers/specs/2026-09-12-localization-and-language-switching-design.md`

## Global Constraints

- Platform: macOS 13.0+
- Swift 6 strict concurrency and `@MainActor` safety
- Design System: `JYLTheme` tokens
- Dynamic Switching: Language changes must take effect immediately without requiring an application restart
- Key Parity: 100% key parity between Chinese and English string dictionaries
- Scratch/Test scripts: `<project>/.temp/`, NEVER `/tmp`

---

### Task 1: Core Localization Infrastructure (`LocalizationManager` & `L10n`)

**Files:**
- Create: `NotchNotch/Localization/LocalizationManager.swift`
- Create: `NotchNotch/Localization/L10n.swift`
- Test: `.temp/test_localization.swift`

**Interfaces:**
- Produces:
  - `enum AppLanguage: String, CaseIterable, Identifiable, Codable, Sendable` (.system, .zhHans, .en)
  - `@MainActor public final class LocalizationManager: ObservableObject`:
    - `public static let shared = LocalizationManager()`
    - `@Published public var language: AppLanguage`
    - `@Published public private(set) var activeCode: String`
    - `public var isChinese: Bool`
    - `public func setLanguage(_ lang: AppLanguage)`
  - `enum L10nKey: String, CaseIterable, Sendable`: exhaustive enum of all string keys
  - `struct L10n`:
    - `public static func tr(_ key: L10nKey) -> String`
    - `public static func tr(_ key: L10nKey, _ args: CVarArg...) -> String`

- [ ] **Step 1: Write test verifying key parity and language resolution**

Create `.temp/test_localization.swift`:
```swift
import Foundation

print("Testing Localization & L10n Key Parity...")
// Verify all L10nKey values exist in both zh-Hans and en dictionaries
for key in L10nKey.allCases {
    let zh = L10n.string(for: key, languageCode: "zh-Hans")
    let en = L10n.string(for: key, languageCode: "en")
    assert(!zh.isEmpty, "Missing Chinese translation for key: \(key)")
    assert(!en.isEmpty, "Missing English translation for key: \(key)")
}

// Test formatting interpolation
let formattedZh = L10n.format(key: .weatherUpdatedAt, languageCode: "zh-Hans", "12:00")
assert(formattedZh.contains("12:00"), "Formatting failed for zh-Hans")
let formattedEn = L10n.format(key: .weatherUpdatedAt, languageCode: "en", "12:00")
assert(formattedEn.contains("12:00"), "Formatting failed for en")

print("Localization tests passed successfully!")
```

- [ ] **Step 2: Implement `NotchNotch/Localization/LocalizationManager.swift`**

Implement:
- `AppLanguage` enum with `system`, `zhHans`, `en` cases and localized `displayName`.
- `LocalizationManager` reading `co.jianyuelab.NotchNotch.appLanguage` from `UserDefaults.standard` (defaulting to `.system`).
- System language resolution via `Locale.preferredLanguages.first`: if starts with "zh", use "zh-Hans", otherwise "en".
- Method `setLanguage(_:)` updating `UserDefaults` and `@Published` properties.

- [ ] **Step 3: Implement `NotchNotch/Localization/L10n.swift`**

Implement:
- `L10nKey` with cases for:
  - Navigation tabs (`tabOverview`, `tabWeather`, `tabShelf`, `tabClipboard`)
  - Weather card (`weatherHourly`, `weatherNow`, `weatherApparent`, `weatherHumidity`, `weatherRain`, `weatherJustUpdated`, `weatherUpdatedAt`, `weatherFetching`, `weatherRetry`, `weatherRefresh`)
  - Media player (`mediaNotPlaying`, `mediaUnknownTrack`, `mediaUnknownArtist`)
  - Schedule (`scheduleNoEvents`, `scheduleInProgress`, `scheduleUpcoming`, `scheduleRemaining`, `scheduleElapsed`)
  - Shelf (`shelfEmptyTitle`, `shelfEmptySubtitle`, `shelfClearAll`, `shelfRevealInFinder`, `shelfAirDrop`)
  - Clipboard (`clipboardEmptyTitle`, `clipboardCopied`, `clipboardClearAll`)
  - Settings tabs (`settingsTabGeneral`, `settingsTabWeather`, `settingsTabAgent`, `settingsTabClipboard`, `settingsTabAbout`)
  - Settings strings (all titles, descriptions, badges, button labels)
  - Menu items (`menuOpenPanel`, `menuSettings`, `menuLaunchAtLogin`, `menuQuit`)
- Dictionaries `zhDictionary: [L10nKey: String]` and `enDictionary: [L10nKey: String]`.
- Static accessor functions querying `LocalizationManager.shared.activeCode`.

- [ ] **Step 4: Run test and build verification**

Run: `swift NotchNotch/Localization/LocalizationManager.swift NotchNotch/Localization/L10n.swift .temp/test_localization.swift`
Expected: PASS with "Localization tests passed successfully!"
Run: `xcodebuild -scheme NotchNotch -configuration Debug build`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add NotchNotch/Localization/
git commit -m "feat(l10n): add LocalizationManager and L10n string tables with 100% key parity"
```

---

### Task 2: Weather Subsystem & WMO Bilingual Support

**Files:**
- Modify: `NotchNotch/Weather/WeatherModels.swift`
- Modify: `NotchNotch/Views/WeatherCardView.swift`

**Interfaces:**
- Consumes: `LocalizationManager.shared`, `L10n`, `L10nKey`
- Modifies:
  - `WMOCodeHelper.description(for:isChinese:) -> String`
  - `WeatherCardView`: observe `LocalizationManager.shared`, replace hardcoded strings with `L10n.tr(...)`

- [ ] **Step 1: Update `WMOCodeHelper` in `WeatherModels.swift`**

Add bilingual parameter:
```swift
public static func description(for code: Int, isChinese: Bool = LocalizationManager.shared.isChinese) -> String
```
Provide English weather descriptions (e.g. "Clear Sky", "Partly Cloudy", "Overcast", "Fog", "Drizzle", "Light Rain", "Heavy Rain", "Snow", "Thunderstorm") alongside the existing Chinese descriptions.

- [ ] **Step 2: Update `WeatherCardView.swift` to use `L10n`**

- Add `@ObservedObject private var loc = LocalizationManager.shared`.
- Replace hardcoded strings:
  - "逐小时预报" -> `L10n.tr(.weatherHourly)`
  - "现在" -> `L10n.tr(.weatherNow)`
  - "体感" -> `L10n.tr(.weatherApparent)`
  - "湿度" -> `L10n.tr(.weatherHumidity)`
  - "降水" -> `L10n.tr(.weatherRain)`
  - "刚刚更新" -> `L10n.tr(.weatherJustUpdated)`
  - String.localizedStringWithFormat(L10n.tr(.weatherUpdatedAt), time)
  - "获取天气信息中..." -> `L10n.tr(.weatherFetching)`
  - "点击重试" -> `L10n.tr(.weatherRetry)`
  - "刷新天气" -> `L10n.tr(.weatherRefresh)`

- [ ] **Step 3: Verify Xcode build**

Run: `xcodebuild -scheme NotchNotch -configuration Debug build`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add NotchNotch/Weather/WeatherModels.swift NotchNotch/Views/WeatherCardView.swift
git commit -m "feat(weather): localize weather card and add bilingual WMO descriptions"
```

---

### Task 3: Notch Overlay, Navigation Tabs & Core Cards Localization

**Files:**
- Modify: `NotchNotch/Views/NotchPanelView.swift`
- Modify: `NotchNotch/Views/NowPlayingView.swift`
- Modify: `NotchNotch/Views/ScheduleTimelineCardView.swift`
- Modify: `NotchNotch/Views/DropShelfView.swift`
- Modify: `NotchNotch/Views/ClipboardCardView.swift`

**Interfaces:**
- Consumes: `LocalizationManager.shared`, `L10n`
- Modifies:
  - `NotchActiveTab.title(isChinese:)` or display helper
  - `NotchPanelView`: inject `@ObservedObject private var loc = LocalizationManager.shared`
  - All cards: replace hardcoded text with `L10n.tr(...)`

- [ ] **Step 1: Localize navigation tabs and ear badges in `NotchPanelView.swift`**

- Add `@ObservedObject private var loc = LocalizationManager.shared`.
- Add method on `NotchActiveTab`:
  ```swift
  var title: String {
      switch self {
      case .overview: return L10n.tr(.tabOverview)
      case .weather: return L10n.tr(.tabWeather)
      case .shelf: return L10n.tr(.tabShelf)
      case .clipboard: return L10n.tr(.tabClipboard)
      }
  }
  ```

- [ ] **Step 2: Localize `NowPlayingView.swift`, `ScheduleTimelineCardView.swift`, `DropShelfView.swift`, `ClipboardCardView.swift`**

- In `NowPlayingView.swift`: replace "未在播放" -> `L10n.tr(.mediaNotPlaying)`
- In `ScheduleTimelineCardView.swift`: replace "今日暂无后续日程", "剩余", "已进行" with `L10n`
- In `DropShelfView.swift`: replace "拖放文件暂存于此", "清空暂存架", "在访达中显示", "隔空投送" with `L10n`
- In `ClipboardCardView.swift`: replace "剪贴板历史为空", "已复制到剪贴板", "清除全部" with `L10n`

- [ ] **Step 3: Verify Xcode build**

Run: `xcodebuild -scheme NotchNotch -configuration Debug build`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add NotchNotch/Views/
git commit -m "feat(l10n): localize notch panel tabs, now playing, schedule, shelf and clipboard"
```

---

### Task 4: Settings Window Localization & Language Switcher

**Files:**
- Modify: `NotchNotch/Views/SettingsView.swift`

**Interfaces:**
- Consumes: `LocalizationManager.shared`, `L10n`
- Modifies:
  - `SettingsTab.title`: dynamic title based on active language
  - `SettingsView`: observe `LocalizationManager.shared`
  - In `generalSection`: add "界面语言 / Language" card with `Picker` bound to `LocalizationManager.shared.language`
  - Localize all text, toggles, labels, descriptions across `generalSection`, `weatherSection`, `agentSection`, `clipboardSection`, and `aboutSection`.

- [ ] **Step 1: Add Language card to General settings**

Add language card with globe icon and segmented control for `AppLanguage.allCases`.
When user changes selection, call `LocalizationManager.shared.setLanguage(newLang)`.

- [ ] **Step 2: Localize all 5 settings tabs using `L10n`**

Ensure every title, description, badge ("已启用" / "Enabled", "已关闭" / "Disabled"), picker option ("摄氏度" / "Celsius", "自动定位" / "Auto GPS/IP"), and button uses `L10n.tr(...)`.

- [ ] **Step 3: Verify Xcode build**

Run: `xcodebuild -scheme NotchNotch -configuration Debug build`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add NotchNotch/Views/SettingsView.swift
git commit -m "feat(settings): add language switcher and localize all settings sections"
```

---

### Task 5: MenuBarExtra Localization, Verification & Cleanup

**Files:**
- Modify: `NotchNotch/NotchNotchApp.swift`
- Clean: `.temp/`

**Interfaces:**
- Consumes: `LocalizationManager.shared`, `L10n`

- [ ] **Step 1: Localize MenuBarExtra in `NotchNotchApp.swift`**

Inject `@ObservedObject private var loc = LocalizationManager.shared` into `NotchNotchApp` (or MenuBar view), localizing menu actions:
- "展开刘海面板" / "Open Notch Panel"
- "偏好设置..." / "Settings..."
- "退出 NotchNotch" / "Quit NotchNotch"

- [ ] **Step 2: Clean up scratch test files in `.temp/`**

Remove `.temp/` directory.

- [ ] **Step 3: Run full Release build**

Run: `xcodebuild -scheme NotchNotch -configuration Release build`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add NotchNotch/NotchNotchApp.swift
git commit -m "feat(menu): localize MenuBarExtra items and finalize release build"
```
