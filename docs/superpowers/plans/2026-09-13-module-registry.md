# Module Registry Implementation Plan (Plugin System — Phase 1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace NotchNotch's three hardcoded feature-registration sites (the `NotchActiveTab` enum, the collapsed-ear `if/else` chains, and the duplicated `hasLiveActivity` aggregation) with one `ModuleRegistry`, so that later phases can register JS plugins through the same surface built-in features use.

**Architecture:** A `@MainActor` `ModuleRegistry` owns an ordered list of `NotchModule` conformers. Six thin adapters wrap the existing controllers; **no existing card view or controller is rewritten**. Ears and alerts become declarative value types (`EarState`, `AlertRequest`) selected by priority, which is what makes them expressible later by a plugin that has no live JS context. Pure logic (ear selection, alert queueing, module ordering) is deliberately separated from SwiftUI so it is checkable by standalone `swiftc` scripts, since this project has no test target.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI + AppKit, Combine, macOS 13.0+. No package dependencies.

**Spec:** `docs/superpowers/specs/2026-09-13-plugin-system-design.md` (§2 Module Registry; §6 Observability & Verification)

## Global Constraints

- **Swift 6 strict concurrency.** UI and controllers are `@MainActor`; pure value types and namespaces are marked `nonisolated`.
- **There is no test target.** Pure-logic verification uses standalone `swiftc` scripts under `.temp/` (gitignored). UI verification is build → launch → `log stream` → `screencapture`.
- **Scratch files go in `<project>/.temp/`, never `/tmp`.** Delete `.temp/` when the plan is complete.
- **Comments explain *why*.** This codebase's comments are accumulated debugging history — preserve every existing one you move, and write new ones in the same register.
- **Design tokens only.** Use `JYLTheme.*` colours and `.jylCard()`, never literal colours.
- **Localization parity is 100%.** Every new user-facing string needs a key in `L10nKey` **and** an entry in *both* the Chinese and English tables in `Localization/L10n.swift`.
- **Tunable numbers live in `App/NotchConfiguration.swift`**, not at the use site.
- **Layout invariant:** the expanded panel's vertical budget is exactly `7 + 26 + 7 + NotchConfiguration.expandedContentRowHeight (120) + 14 = 174`. Every tab slot stays pinned to the row height and `.clipped()`.
- **Coordinate space:** everything in `Notch/` is AppKit screen coordinates (bottom-left origin, +Y up).
- **Commits** use Conventional Commits with a scope, e.g. `refactor(modules):`.
- **Only one process may bind port 7823.** Run `pkill -f NotchNotch` before every relaunch.

### Standard commands

```bash
# Build
xcodebuild -scheme NotchNotch -configuration Debug -derivedDataPath build/DerivedData build

# Relaunch with logs
pkill -f NotchNotch; sleep 1
build/DerivedData/Build/Products/Debug/NotchNotch.app/Contents/MacOS/NotchNotch 2>&1 | tee .temp/app_stdout.log &

# Expand the panel headlessly, then capture it
swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(
  Notification.Name("co.jianyuelab.NotchNotch.expand"), object: nil, deliverImmediately: true)'
screencapture -x .temp/shot.png
```

### Standard pure-logic test harness

Each pure-logic task compiles the real source files together with a throwaway `main.swift`. The test file **must** be named `main.swift` — `swiftc` only permits top-level code in a file with that name.

```bash
mkdir -p .temp/t_<name>
# write .temp/t_<name>/main.swift
swiftc -swift-version 6 -o .temp/t_<name>/run \
  NotchNotch/Modules/<Source>.swift .temp/t_<name>/main.swift && .temp/t_<name>/run
```

If `-swift-version 6` produces concurrency noise unrelated to the assertion under test, drop to `-swift-version 5` and note it in the commit body — do not silence the warning in production source to make a scratch script happy.

### Accepted visual deltas

The current ear code uses three ring diameters (18/19/20pt), three stroke widths (2.5/2.8/3.2pt), four chip sizes (21/22pt) and four corner radii (5.5/6/6.5pt) for what are visually the same component. Collapsing them into one template normalizes these to **22pt chips at radius 6** and **20pt rings at 3.0pt stroke**, and merges the two `#a78bfa` fill opacities (0.20 and 0.22) into one at 0.20.

This is a deliberate, tiny normalization, not an accident. Task 6 requires screenshot sign-off before it is accepted.

---

## File Structure

**Create:**

| File | Responsibility |
|---|---|
| `NotchNotch/Modules/ThemeToken.swift` | Closed enum of nameable palette colours. Pure Foundation. |
| `NotchNotch/Modules/ThemeToken+Color.swift` | `ThemeToken → SwiftUI.Color`. The only SwiftUI-aware half. |
| `NotchNotch/Modules/EarState.swift` | Declarative ear template + `EarSelection` priority resolution. Pure. |
| `NotchNotch/Modules/AlertRequest.swift` | Declarative alert template + `AlertQueueLogic`. Pure. |
| `NotchNotch/Modules/ModuleOrdering.swift` | Order/enablement resolution + legacy tab-name mapping. Pure. |
| `NotchNotch/Modules/NotchModule.swift` | The surface protocol and its defaults. |
| `NotchNotch/Modules/ModuleRegistry.swift` | `@MainActor` owner of modules, ear selection, alert queue, persistence. |
| `NotchNotch/Modules/BuiltIn/OverviewModule.swift` | Pinned first tab; wraps the existing media + schedule card pair. |
| `NotchNotch/Modules/BuiltIn/WeatherModule.swift` | Card + ear; wraps `WeatherController.shared`. |
| `NotchNotch/Modules/BuiltIn/ShelfModule.swift` | Card + badge; wraps the injected `ShelfController`. |
| `NotchNotch/Modules/BuiltIn/ClipboardModule.swift` | Card; wraps `ClipboardManager.shared`. |
| `NotchNotch/Modules/BuiltIn/AgentModule.swift` | Ear + alert only; wraps `AgentHarnessController.shared`. |
| `NotchNotch/Modules/BuiltIn/ScheduleModule.swift` | Ear + alert only; wraps `ScheduleController.shared`. |
| `NotchNotch/Views/EarView.swift` | Renders one `EarState` half. Replaces the `if/else` chains. |
| `NotchNotch/Views/ModulesSettingsCard.swift` | Settings card: reorder and enable/disable tabs. |

**Modify:** `Views/NotchPanelView.swift`, `Notch/NotchWindowController.swift`, `Views/SettingsView.swift:580`, `Localization/L10n.swift`, `App/NotchConfiguration.swift`, `CLAUDE.md`, `NotchNotch.xcodeproj/project.pbxproj`.

**Explicitly untouched:** `NowPlayingView`, `WeatherCardView`, `DropShelfView`, `ClipboardCardView`, `ScheduleTimelineCardView`, and every controller under `Media/`, `Weather/`, `Schedule/`, `Clipboard/`, `Shelf/`, `Agent/`.

---

## Task 1: Theme tokens and the ear template

**Files:**
- Create: `NotchNotch/Modules/ThemeToken.swift`
- Create: `NotchNotch/Modules/ThemeToken+Color.swift`
- Create: `NotchNotch/Modules/EarState.swift`
- Test: `.temp/t_ear/main.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `ThemeToken` (`String`-raw, `CaseIterable`, `Sendable`); `ThemeToken.color: Color`; `EarState` with `.leading: EarState.Leading`, `.trailing: EarState.Trailing`, `.priority: Int`, `.expiresAt: Date?`, `.isEmpty: Bool`, `.isExpired(at: Date) -> Bool`, `.isLive(at: Date) -> Bool`; `EarSelection.Candidate(id: String, state: EarState)`; `EarSelection.select(from: [EarSelection.Candidate], at: Date) -> EarSelection.Candidate?`.

- [ ] **Step 1: Write `ThemeToken.swift`**

```swift
//
//  ThemeToken.swift
//  NotchNotch
//
//  The closed set of palette colours that *declarative* surfaces may name.
//
//  Deliberately a string enum rather than a `Color`: it keeps EarState and
//  AlertRequest free of SwiftUI, so they stay checkable by a standalone
//  `swiftc` script in a project that has no test target — and it makes an
//  off-palette colour unrepresentable rather than merely discouraged.
//

import Foundation

nonisolated public enum ThemeToken: String, CaseIterable, Sendable {
    case primary
    case primaryLight
    case primaryMuted
    case success
    case successMuted
    case warning
    case warningMuted
    case error
    case errorMuted
    case info
    case infoMuted
    case textPrimary
    case textSecondary
    case textMuted
    case border
    case borderStrong
    case neutral700
    case neutral800
    case chart1
    case chart2
    case chart3
    case chart3Muted
    case chart4
    case chart5
    case white
    /// `Color.white.opacity(0.12)` — the neutral chip fill the weather ear uses.
    case whiteMuted
}
```

- [ ] **Step 2: Write `ThemeToken+Color.swift`**

```swift
//
//  ThemeToken+Color.swift
//  NotchNotch
//
//  The SwiftUI half of ThemeToken, kept in its own file so the value types that
//  name tokens stay compilable without SwiftUI.
//

import SwiftUI

extension ThemeToken {
    var color: Color {
        switch self {
        case .primary:       return JYLTheme.primary
        case .primaryLight:  return JYLTheme.primaryLight
        case .primaryMuted:  return JYLTheme.primaryMuted
        case .success:       return JYLTheme.success
        case .successMuted:  return JYLTheme.successMuted
        case .warning:       return JYLTheme.warning
        case .warningMuted:  return JYLTheme.warningMuted
        case .error:         return JYLTheme.error
        case .errorMuted:    return JYLTheme.errorMuted
        case .info:          return JYLTheme.info
        case .infoMuted:     return JYLTheme.infoMuted
        case .textPrimary:   return JYLTheme.textPrimary
        case .textSecondary: return JYLTheme.textSecondary
        case .textMuted:     return JYLTheme.textMuted
        case .border:        return JYLTheme.border
        case .borderStrong:  return JYLTheme.borderStrong
        case .neutral700:    return JYLTheme.neutral700
        case .neutral800:    return JYLTheme.neutral800
        case .chart1:        return JYLTheme.chart1
        case .chart2:        return JYLTheme.chart2
        case .chart3:        return JYLTheme.chart3
        case .chart3Muted:   return Color(hex: "#a78bfa", opacity: 0.20)
        case .chart4:        return JYLTheme.chart4
        case .chart5:        return JYLTheme.chart5
        case .white:         return .white
        case .whiteMuted:    return Color.white.opacity(0.12)
        }
    }
}
```

- [ ] **Step 3: Write `EarState.swift`**

The five cases below are not speculative — between them they reproduce every ear that exists in `NotchPanelView.compactLeftEar` / `compactRightEar` today.

```swift
//
//  EarState.swift
//  NotchNotch
//
//  A collapsed-pill ear, expressed as data rather than as a branch in a view.
//
//  WHY data: a plugin that is dormant has no live JS context, so it cannot be
//  asked to render. Persisting an EarState lets its ear keep displaying with
//  nothing running behind it. The same shape then serves the built-ins, which
//  is what collapses the ~130-line if/else chains into one template.
//

import AppKit

nonisolated public struct EarState: Equatable {

    public enum Leading: Equatable {
        case none
        case icon(symbol: String, tint: ThemeToken, fill: ThemeToken)
        /// The brand-gradient chip the music ear falls back to with no artwork.
        case brandIcon(symbol: String)
        case artwork(NSImage)
    }

    public enum Trailing: Equatable {
        case none
        case ring(progress: Double, tint: ThemeToken, track: ThemeToken)
        case gradientRing(progress: Double, from: ThemeToken, to: ThemeToken, track: ThemeToken)
        case spinner(tint: ThemeToken, track: ThemeToken)
        case text(String, tint: ThemeToken)
        case badge(String, tint: ThemeToken, fill: ThemeToken)
    }

    public var leading: Leading
    public var trailing: Trailing
    /// Higher wins. Built-ins are seeded to reproduce today's precedence:
    /// music 400 > agent 300 > schedule 200 > weather 100. Plugins sit below.
    public var priority: Int
    /// Lets a dormant plugin's persisted ear retire itself without JS running.
    public var expiresAt: Date?

    public init(leading: Leading,
                trailing: Trailing,
                priority: Int,
                expiresAt: Date? = nil) {
        self.leading = leading
        self.trailing = trailing
        self.priority = priority
        self.expiresAt = expiresAt
    }

    public var isEmpty: Bool { leading == .none && trailing == .none }

    public func isExpired(at now: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }

    public func isLive(at now: Date) -> Bool { !isEmpty && !isExpired(at: now) }
}

nonisolated public enum EarSelection {

    public struct Candidate: Equatable {
        public let id: String
        public let state: EarState
        public init(id: String, state: EarState) {
            self.id = id
            self.state = state
        }
    }

    /// Highest priority live candidate wins. Ties break on the lexicographically
    /// smallest id purely so the choice is deterministic — two modules claiming
    /// the same priority is a configuration mistake, not a runtime decision.
    public static func select(from candidates: [Candidate], at now: Date) -> Candidate? {
        candidates
            .filter { $0.state.isLive(at: now) }
            .max { a, b in
                if a.state.priority != b.state.priority {
                    return a.state.priority < b.state.priority
                }
                return a.id > b.id
            }
    }
}
```

- [ ] **Step 4: Write the failing test**

Create `.temp/t_ear/main.swift`:

```swift
import Foundation

var failures = 0
func check(_ condition: Bool, _ label: String) {
    if condition { print("  ok   \(label)") }
    else { print("  FAIL \(label)"); failures += 1 }
}

let now = Date(timeIntervalSince1970: 1_000_000)
func ear(_ priority: Int, expires: Date? = nil) -> EarState {
    EarState(leading: .icon(symbol: "star", tint: .primary, fill: .primaryMuted),
             trailing: .text("x", tint: .primary),
             priority: priority,
             expiresAt: expires)
}

print("EarState")
check(EarState(leading: .none, trailing: .none, priority: 0).isEmpty,
      "an all-none ear is empty")
check(!ear(1).isEmpty, "a populated ear is not empty")
check(ear(1, expires: now.addingTimeInterval(-1)).isExpired(at: now),
      "an ear whose expiry has passed is expired")
check(!ear(1, expires: now.addingTimeInterval(60)).isExpired(at: now),
      "an ear expiring later is not expired")
check(!ear(1).isExpired(at: now), "an ear with no expiry never expires")
check(!EarState(leading: .none, trailing: .none, priority: 0).isLive(at: now),
      "an empty ear is not live")
check(!ear(1, expires: now.addingTimeInterval(-1)).isLive(at: now),
      "an expired ear is not live")

print("EarSelection")
check(EarSelection.select(from: [], at: now) == nil,
      "no candidates selects nothing")
check(EarSelection.select(from: [
        .init(id: "a", state: ear(100)),
        .init(id: "b", state: ear(400)),
        .init(id: "c", state: ear(200)),
      ], at: now)?.id == "b",
      "highest priority wins")
check(EarSelection.select(from: [
        .init(id: "a", state: ear(100)),
        .init(id: "b", state: ear(400, expires: now.addingTimeInterval(-1))),
      ], at: now)?.id == "a",
      "an expired high-priority ear yields to a live lower one")
check(EarSelection.select(from: [
        .init(id: "zzz", state: ear(100)),
        .init(id: "aaa", state: ear(100)),
      ], at: now)?.id == "aaa",
      "equal priority breaks deterministically on the smallest id")
check(EarSelection.select(from: [
        .init(id: "a", state: EarState(leading: .none, trailing: .none, priority: 999)),
      ], at: now) == nil,
      "an empty ear is never selected however high its priority")

print(failures == 0 ? "\nPASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
```

- [ ] **Step 5: Run the test and verify it fails**

```bash
mkdir -p .temp/t_ear
swiftc -swift-version 6 -o .temp/t_ear/run \
  NotchNotch/Modules/ThemeToken.swift NotchNotch/Modules/EarState.swift \
  .temp/t_ear/main.swift && .temp/t_ear/run
```

Expected before Step 3 exists: a compile error naming `EarState`. If you wrote Step 3 first, delete `NotchNotch/Modules/EarState.swift`, confirm the failure, then restore it — a test that has never been seen to fail proves nothing.

- [ ] **Step 6: Run the test and verify it passes**

```bash
swiftc -swift-version 6 -o .temp/t_ear/run \
  NotchNotch/Modules/ThemeToken.swift NotchNotch/Modules/EarState.swift \
  .temp/t_ear/main.swift && .temp/t_ear/run
```

Expected: 12 `ok` lines and `PASS`, exit 0.

- [ ] **Step 7: Verify the app still builds**

```bash
xcodebuild -scheme NotchNotch -configuration Debug -derivedDataPath build/DerivedData build
```

Expected: `BUILD SUCCEEDED`. New files must be added to the Xcode target — if `xcodebuild` does not pick them up automatically, add them to the `NotchNotch` target's Sources build phase in `NotchNotch.xcodeproj/project.pbxproj`.

- [ ] **Step 8: Commit**

```bash
git add NotchNotch/Modules/ThemeToken.swift NotchNotch/Modules/ThemeToken+Color.swift \
        NotchNotch/Modules/EarState.swift NotchNotch.xcodeproj/project.pbxproj
git commit -m "feat(modules): add ThemeToken and the declarative EarState template"
```

---

## Task 2: Alert template and queue logic

**Files:**
- Create: `NotchNotch/Modules/AlertRequest.swift`
- Test: `.temp/t_alert/main.swift`

**Interfaces:**
- Consumes: `ThemeToken` (Task 1).
- Produces: `AlertAction` (`.none`, `.openModule(String)`, `.openURL(URL)`, `.focusAgentSession`, `.expandPanel`); `AlertRequest(id:moduleID:icon:tint:title:badge:action:duration:priority:postedAt:)` with `.expiresAt: Date`; `AlertQueueLogic.active(in: [AlertRequest], at: Date) -> AlertRequest?`; `AlertQueueLogic.pruned(_: [AlertRequest], at: Date) -> [AlertRequest]`.

- [ ] **Step 1: Write `AlertRequest.swift`**

```swift
//
//  AlertRequest.swift
//  NotchNotch
//
//  A transient banner that takes over the collapsed panel.
//
//  WHY a queue rather than a boolean per feature: today the agent banner and
//  the schedule banner are separate branches that cannot express "the schedule
//  alert is more urgent than the agent one". Once plugins can post banners too,
//  an explicit priority is the only thing preventing them fighting each other.
//

import Foundation

nonisolated public enum AlertAction: Equatable {
    case none
    case openModule(String)
    case openURL(URL)
    case focusAgentSession
    /// Dismiss and expand the panel — what the schedule banner does today.
    case expandPanel
}

nonisolated public struct AlertRequest: Equatable, Identifiable {
    public let id: UUID
    public let moduleID: String
    public let icon: String
    public let tint: ThemeToken
    public let title: String
    public let badge: String?
    public let action: AlertAction
    public let duration: TimeInterval
    /// Higher wins. Schedule 300 > agent 200 > plugins 100 by default.
    public let priority: Int
    public let postedAt: Date

    public init(id: UUID = UUID(),
                moduleID: String,
                icon: String,
                tint: ThemeToken,
                title: String,
                badge: String? = nil,
                action: AlertAction = .none,
                duration: TimeInterval,
                priority: Int,
                postedAt: Date) {
        self.id = id
        self.moduleID = moduleID
        self.icon = icon
        self.tint = tint
        self.title = title
        self.badge = badge
        self.action = action
        self.duration = duration
        self.priority = priority
        self.postedAt = postedAt
    }

    public var expiresAt: Date { postedAt.addingTimeInterval(duration) }

    public func isExpired(at now: Date) -> Bool { expiresAt <= now }
}

nonisolated public enum AlertQueueLogic {

    /// Highest-priority unexpired request. Ties go to the most recently posted,
    /// so a repeat notification from the same module visibly refreshes.
    public static func active(in requests: [AlertRequest], at now: Date) -> AlertRequest? {
        requests
            .filter { !$0.isExpired(at: now) }
            .max { a, b in
                if a.priority != b.priority { return a.priority < b.priority }
                return a.postedAt < b.postedAt
            }
    }

    public static func pruned(_ requests: [AlertRequest], at now: Date) -> [AlertRequest] {
        requests.filter { !$0.isExpired(at: now) }
    }
}
```

- [ ] **Step 2: Write the failing test**

Create `.temp/t_alert/main.swift`:

```swift
import Foundation

var failures = 0
func check(_ condition: Bool, _ label: String) {
    if condition { print("  ok   \(label)") }
    else { print("  FAIL \(label)"); failures += 1 }
}

let t0 = Date(timeIntervalSince1970: 1_000_000)
func alert(_ moduleID: String,
           priority: Int,
           posted: TimeInterval,
           duration: TimeInterval = 5) -> AlertRequest {
    AlertRequest(moduleID: moduleID,
                 icon: "bell",
                 tint: .primary,
                 title: moduleID,
                 duration: duration,
                 priority: priority,
                 postedAt: t0.addingTimeInterval(posted))
}

print("AlertRequest")
check(alert("a", priority: 1, posted: 0).expiresAt == t0.addingTimeInterval(5),
      "expiry is postedAt plus duration")
check(alert("a", priority: 1, posted: 0).isExpired(at: t0.addingTimeInterval(5)),
      "an alert is expired exactly at its expiry instant")
check(!alert("a", priority: 1, posted: 0).isExpired(at: t0.addingTimeInterval(4.9)),
      "an alert is live just before expiry")

print("AlertQueueLogic")
check(AlertQueueLogic.active(in: [], at: t0) == nil,
      "an empty queue has no active alert")
check(AlertQueueLogic.active(in: [
        alert("agent", priority: 200, posted: 0),
        alert("schedule", priority: 300, posted: 0),
      ], at: t0)?.moduleID == "schedule",
      "higher priority wins")
check(AlertQueueLogic.active(in: [
        alert("first", priority: 200, posted: 0),
        alert("second", priority: 200, posted: 1),
      ], at: t0.addingTimeInterval(1))?.moduleID == "second",
      "equal priority resolves to the most recently posted")
check(AlertQueueLogic.active(in: [
        alert("schedule", priority: 300, posted: 0, duration: 1),
        alert("agent", priority: 200, posted: 0, duration: 10),
      ], at: t0.addingTimeInterval(2))?.moduleID == "agent",
      "an expired high-priority alert yields to a live lower one")
check(AlertQueueLogic.pruned([
        alert("a", priority: 1, posted: 0, duration: 1),
        alert("b", priority: 1, posted: 0, duration: 10),
      ], at: t0.addingTimeInterval(2)).map(\.moduleID) == ["b"],
      "pruning drops exactly the expired requests")

print(failures == 0 ? "\nPASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
```

- [ ] **Step 3: Run the test and verify it fails**

```bash
mkdir -p .temp/t_alert
mv NotchNotch/Modules/AlertRequest.swift .temp/AlertRequest.swift.bak
swiftc -swift-version 6 -o .temp/t_alert/run \
  NotchNotch/Modules/ThemeToken.swift .temp/t_alert/main.swift && .temp/t_alert/run
```

Expected: compile error, `cannot find 'AlertRequest' in scope`.

- [ ] **Step 4: Restore the implementation and verify the test passes**

```bash
mv .temp/AlertRequest.swift.bak NotchNotch/Modules/AlertRequest.swift
swiftc -swift-version 6 -o .temp/t_alert/run \
  NotchNotch/Modules/ThemeToken.swift NotchNotch/Modules/AlertRequest.swift \
  .temp/t_alert/main.swift && .temp/t_alert/run
```

Expected: 7 `ok` lines and `PASS`, exit 0.

- [ ] **Step 5: Build and commit**

```bash
xcodebuild -scheme NotchNotch -configuration Debug -derivedDataPath build/DerivedData build
git add NotchNotch/Modules/AlertRequest.swift NotchNotch.xcodeproj/project.pbxproj
git commit -m "feat(modules): add AlertRequest and priority queue logic"
```

---

## Task 3: Module ordering logic

**Files:**
- Create: `NotchNotch/Modules/ModuleOrdering.swift`
- Test: `.temp/t_order/main.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `ModuleOrdering.pinnedFirstID: String` (`"builtin.overview"`); `ModuleOrdering.resolve(available: [String], persistedOrder: [String], disabled: Set<String>) -> [String]`; `ModuleOrdering.moduleID(forLegacyTabName: String) -> String?`.

- [ ] **Step 1: Write `ModuleOrdering.swift`**

```swift
//
//  ModuleOrdering.swift
//  NotchNotch
//
//  Pure resolution of "which tabs are shown, in what order".
//
//  Separated from ModuleRegistry so it can be checked by a standalone script:
//  the ordering rules (pinned first, unknown modules appended, stale persisted
//  ids dropped) are exactly the kind of thing that silently rots once plugins
//  can be installed and uninstalled between launches.
//

import Foundation

nonisolated public enum ModuleOrdering {

    /// Overview is the state the panel resets to on collapse, so it must always
    /// exist and must always be reachable first.
    public static let pinnedFirstID = "builtin.overview"

    /// - Parameters:
    ///   - available: every registered card-providing module id, in registration order.
    ///   - persistedOrder: the user's saved order. May name modules that no longer exist.
    ///   - disabled: user-hidden module ids. `pinnedFirstID` is ignored if present.
    public static func resolve(available: [String],
                               persistedOrder: [String],
                               disabled: Set<String>) -> [String] {
        let availableSet = Set(available)

        // Saved order first, minus anything that has since been uninstalled.
        var ordered = persistedOrder.filter { availableSet.contains($0) }

        // Then anything installed since the order was saved, in registration order.
        for id in available where !ordered.contains(id) {
            ordered.append(id)
        }

        // Overview is pinned regardless of what the persisted order claims.
        ordered.removeAll { $0 == pinnedFirstID }
        if availableSet.contains(pinnedFirstID) {
            ordered.insert(pinnedFirstID, at: 0)
        }

        return ordered.filter { $0 == pinnedFirstID || !disabled.contains($0) }
    }

    /// The `co.jianyuelab.NotchNotch.selectTab` notification is the project's
    /// documented headless verification path, so its original vocabulary has to
    /// keep working forever. Note these are the lowercase notification names,
    /// not the old `NotchActiveTab` raw values.
    public static func moduleID(forLegacyTabName name: String) -> String? {
        switch name {
        case "overview":  return "builtin.overview"
        case "weather":   return "builtin.weather"
        case "shelf":     return "builtin.shelf"
        case "clipboard": return "builtin.clipboard"
        default:          return nil
        }
    }
}
```

- [ ] **Step 2: Write the failing test**

Create `.temp/t_order/main.swift`:

```swift
import Foundation

var failures = 0
func check(_ condition: Bool, _ label: String) {
    if condition { print("  ok   \(label)") }
    else { print("  FAIL \(label)"); failures += 1 }
}

let builtins = ["builtin.overview", "builtin.weather", "builtin.shelf", "builtin.clipboard"]

print("ModuleOrdering.resolve")
check(ModuleOrdering.resolve(available: builtins, persistedOrder: [], disabled: [])
        == builtins,
      "with no saved order, registration order is preserved")

check(ModuleOrdering.resolve(available: builtins,
                             persistedOrder: ["builtin.clipboard", "builtin.weather"],
                             disabled: [])
        == ["builtin.overview", "builtin.clipboard", "builtin.weather", "builtin.shelf"],
      "saved order is honoured and unsaved modules are appended")

check(ModuleOrdering.resolve(available: builtins,
                             persistedOrder: ["builtin.weather", "builtin.overview"],
                             disabled: []).first == "builtin.overview",
      "overview is pinned first even when saved elsewhere")

check(ModuleOrdering.resolve(available: builtins,
                             persistedOrder: ["plugin.gone", "builtin.weather"],
                             disabled: [])
        == ["builtin.overview", "builtin.weather", "builtin.shelf", "builtin.clipboard"],
      "a persisted id that no longer exists is dropped")

check(!ModuleOrdering.resolve(available: builtins,
                              persistedOrder: [],
                              disabled: ["builtin.clipboard"])
        .contains("builtin.clipboard"),
      "a disabled module is hidden")

check(ModuleOrdering.resolve(available: builtins,
                             persistedOrder: [],
                             disabled: ["builtin.overview"])
        .contains("builtin.overview"),
      "overview cannot be disabled")

check(ModuleOrdering.resolve(available: builtins + ["plugin.new"],
                             persistedOrder: builtins,
                             disabled: []).last == "plugin.new",
      "a newly installed plugin lands at the end rather than disappearing")

print("ModuleOrdering.moduleID(forLegacyTabName:)")
for (legacy, expected) in [("overview", "builtin.overview"),
                           ("weather", "builtin.weather"),
                           ("shelf", "builtin.shelf"),
                           ("clipboard", "builtin.clipboard")] {
    check(ModuleOrdering.moduleID(forLegacyTabName: legacy) == expected,
          "\"\(legacy)\" still maps to \(expected)")
}
check(ModuleOrdering.moduleID(forLegacyTabName: "settings") == nil,
      "\"settings\" is not a module and maps to nil")
check(ModuleOrdering.moduleID(forLegacyTabName: "Overview") == nil,
      "the mapping is case-sensitive, matching the documented lowercase names")

print(failures == 0 ? "\nPASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
```

- [ ] **Step 3: Run the test and verify it fails**

```bash
mkdir -p .temp/t_order
mv NotchNotch/Modules/ModuleOrdering.swift .temp/ModuleOrdering.swift.bak
swiftc -swift-version 6 -o .temp/t_order/run .temp/t_order/main.swift && .temp/t_order/run
```

Expected: compile error, `cannot find 'ModuleOrdering' in scope`.

- [ ] **Step 4: Restore and verify it passes**

```bash
mv .temp/ModuleOrdering.swift.bak NotchNotch/Modules/ModuleOrdering.swift
swiftc -swift-version 6 -o .temp/t_order/run \
  NotchNotch/Modules/ModuleOrdering.swift .temp/t_order/main.swift && .temp/t_order/run
```

Expected: 13 `ok` lines and `PASS`, exit 0.

- [ ] **Step 5: Build and commit**

```bash
xcodebuild -scheme NotchNotch -configuration Debug -derivedDataPath build/DerivedData build
git add NotchNotch/Modules/ModuleOrdering.swift NotchNotch.xcodeproj/project.pbxproj
git commit -m "feat(modules): add pure module ordering and legacy tab-name mapping"
```

---

## Task 4: The `NotchModule` protocol and `ModuleRegistry`

**Files:**
- Create: `NotchNotch/Modules/NotchModule.swift`
- Create: `NotchNotch/Modules/ModuleRegistry.swift`
- Modify: `NotchNotch/Support/Log.swift`
- Modify: `NotchNotch/App/NotchConfiguration.swift`

**Interfaces:**
- Consumes: `EarState`, `EarSelection` (Task 1); `AlertRequest`, `AlertQueueLogic` (Task 2); `ModuleOrdering` (Task 3).
- Produces: protocol `NotchModule` with `id`, `title`, `iconName`, `badge`, `providesCard`, `canBeDisabled`, `cardView()`, `earStatePublisher`; `ModuleRegistry.shared` with `@Published visibleModules: [any NotchModule]`, `@Published hasLiveActivity: Bool`, `@Published activeEar: EarSelection.Candidate?`, `@Published activeAlert: AlertRequest?`, `@Published activeModuleID: String`, and methods `register(_:)`, `finishRegistration()`, `post(_:)`, `dismissAlert()`, `dismissAlerts(from:)`, `select(moduleID:)`, `selectLegacy(tabName:) -> Bool`, `resetToOverview()`, `setEnabled(_:for:)`, `isEnabled(_:)`, `move(id:direction:)`.

- [ ] **Step 1: Add the `modules` log category**

In `NotchNotch/Support/Log.swift`, after the `media` line inside `enum Log`:

```swift
    static let modules   = Logger(subsystem: subsystem, category: "modules")
```

- [ ] **Step 2: Add the alert-duration constants**

In `NotchNotch/App/NotchConfiguration.swift`, append inside the configuration enum:

```swift
    // MARK: - Modules

    /// How long a posted banner stays up before the queue retires it. The two
    /// built-ins previously hardcoded their own timers; the queue owns it now.
    static let moduleAlertDuration: TimeInterval = 4.0

    /// Ear precedence. Seeded to reproduce the original if/else order exactly:
    /// music beat agent, which beat schedule, which beat weather.
    static let earPriorityMusic = 400
    static let earPriorityAgent = 300
    static let earPrioritySchedule = 200
    static let earPriorityWeather = 100

    /// Alert precedence: a calendar event starting outranks agent chatter.
    static let alertPrioritySchedule = 300
    static let alertPriorityAgent = 200
```

- [ ] **Step 3: Write `NotchModule.swift`**

```swift
//
//  NotchModule.swift
//  NotchNotch
//
//  One feature's contribution to the notch, across every surface it can occupy.
//
//  Built-in features conform natively and keep their existing SwiftUI cards
//  verbatim; a JS plugin will conform with a card that happens to be rendered
//  from a Vue node tree. Neither the tab bar nor the ear renderer knows which
//  is which, which is the entire point.
//

import SwiftUI
import Combine

@MainActor
protocol NotchModule: AnyObject {

    /// Stable and namespaced: `builtin.weather`, `plugin.co.example.ci`.
    /// Persisted in the tab order, so it must not change between launches.
    var id: String { get }

    /// Already localized — modules call `L10n.tr` themselves rather than
    /// exposing a key, because a plugin's title comes from its manifest.
    var title: String { get }

    /// SF Symbol for the tab button.
    var iconName: String { get }

    /// Small count shown on the tab button, e.g. the shelf's item count.
    var badge: String? { get }

    /// False for modules that only contribute an ear or an alert.
    var providesCard: Bool { get }

    /// False for Overview, which the panel resets to on collapse.
    var canBeDisabled: Bool { get }

    func cardView() -> AnyView

    /// Emits this module's ear contribution; `nil` means "not live".
    ///
    /// A publisher rather than a polled property so the registry never has to
    /// ask every module "have you changed?" on a timer.
    var earStatePublisher: AnyPublisher<EarState?, Never> { get }
}

extension NotchModule {
    var badge: String? { nil }
    var providesCard: Bool { true }
    var canBeDisabled: Bool { true }
    func cardView() -> AnyView { AnyView(EmptyView()) }
    var earStatePublisher: AnyPublisher<EarState?, Never> {
        Just(nil).eraseToAnyPublisher()
    }
}
```

- [ ] **Step 4: Write `ModuleRegistry.swift`**

```swift
//
//  ModuleRegistry.swift
//  NotchNotch
//
//  The single place that knows which features exist and which surface is
//  currently showing which one.
//
//  GOTCHA — the reactivity boundary: this object publishes *structural* change
//  only (which modules exist, their order, badges, the selected ear, the active
//  alert). Card views keep observing their own controllers directly, exactly as
//  WeatherCardView observes WeatherController.shared. If leaf reactivity were
//  funnelled through here, a now-playing tick would invalidate the whole panel
//  once per second.
//

import SwiftUI
import Combine

@MainActor
final class ModuleRegistry: ObservableObject {

    static let shared = ModuleRegistry()

    // MARK: Published structure

    @Published private(set) var visibleModules: [any NotchModule] = []
    @Published private(set) var hasLiveActivity: Bool = false
    @Published private(set) var activeEar: EarSelection.Candidate? = nil
    @Published private(set) var activeAlert: AlertRequest? = nil
    @Published private(set) var activeModuleID: String = ModuleOrdering.pinnedFirstID

    // MARK: Storage

    private var modules: [any NotchModule] = []
    private var latestEars: [String: EarState] = [:]
    private var alerts: [AlertRequest] = []
    private var cancellables = Set<AnyCancellable>()
    private var alertTimer: Timer?

    private let orderKey = "co.jianyuelab.NotchNotch.moduleOrder"
    private let disabledKey = "co.jianyuelab.NotchNotch.disabledModules"

    private init() {}

    // MARK: Registration

    /// Call for each module during startup, then `finishRegistration()` once.
    func register(_ module: any NotchModule) {
        guard !modules.contains(where: { $0.id == module.id }) else {
            Log.modules.error("duplicate module id \(module.id, privacy: .public) ignored")
            return
        }
        modules.append(module)

        module.earStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self, id = module.id] state in
                guard let self else { return }
                if let state, state.isLive(at: Date()) {
                    self.latestEars[id] = state
                } else {
                    self.latestEars.removeValue(forKey: id)
                }
                self.recomputeEar()
            }
            .store(in: &cancellables)
    }

    func finishRegistration() {
        rebuildVisibleModules()
        recomputeEar()
        Log.modules.notice("registered \(self.modules.count) modules, \(self.visibleModules.count) visible")
    }

    // MARK: Ordering and enablement

    func isEnabled(_ id: String) -> Bool { !disabledIDs.contains(id) }

    func setEnabled(_ enabled: Bool, for id: String) {
        guard let module = modules.first(where: { $0.id == id }), module.canBeDisabled else { return }
        var disabled = disabledIDs
        if enabled { disabled.remove(id) } else { disabled.insert(id) }
        UserDefaults.standard.set(Array(disabled), forKey: disabledKey)
        rebuildVisibleModules()
        // Never leave the panel pointing at a tab that is no longer shown.
        if !visibleModules.contains(where: { $0.id == activeModuleID }) {
            activeModuleID = ModuleOrdering.pinnedFirstID
        }
    }

    enum MoveDirection { case up, down }

    /// One step at a time, because the Settings card drives this from a pair of
    /// arrow buttons rather than a drag gesture — a custom VStack of cards has
    /// no free reordering affordance, and List's would not match the styling.
    /// Overview is pinned at index 0, so nothing may move above index 1.
    func move(id: String, direction: MoveDirection) {
        var ids = allCardModules.map(\.id)
        guard let index = ids.firstIndex(of: id) else { return }
        let target = direction == .up ? index - 1 : index + 1
        guard target >= 1, target < ids.count else { return }
        ids.swapAt(index, target)
        UserDefaults.standard.set(ids, forKey: orderKey)
        rebuildVisibleModules()
        objectWillChange.send()
    }

    func canMove(id: String, direction: MoveDirection) -> Bool {
        let ids = allCardModules.map(\.id)
        guard let index = ids.firstIndex(of: id) else { return false }
        let target = direction == .up ? index - 1 : index + 1
        return target >= 1 && target < ids.count
    }

    private var disabledIDs: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: disabledKey) ?? [])
    }

    private func rebuildVisibleModules() {
        let cardModules = modules.filter(\.providesCard)
        let order = ModuleOrdering.resolve(
            available: cardModules.map(\.id),
            persistedOrder: UserDefaults.standard.stringArray(forKey: orderKey) ?? [],
            disabled: disabledIDs
        )
        visibleModules = order.compactMap { id in cardModules.first { $0.id == id } }
    }

    // MARK: Selection

    func select(moduleID: String) {
        guard visibleModules.contains(where: { $0.id == moduleID }) else { return }
        activeModuleID = moduleID
    }

    /// Returns false when the name is not a tab (e.g. `"settings"`), so the
    /// caller can handle it. Preserves the documented notification vocabulary.
    func selectLegacy(tabName: String) -> Bool {
        guard let id = ModuleOrdering.moduleID(forLegacyTabName: tabName) else { return false }
        select(moduleID: id)
        return true
    }

    func resetToOverview() {
        activeModuleID = ModuleOrdering.pinnedFirstID
    }

    // MARK: Ears

    private func recomputeEar() {
        let now = Date()
        let candidates = latestEars.map { EarSelection.Candidate(id: $0.key, state: $0.value) }
        let selected = EarSelection.select(from: candidates, at: now)
        if activeEar != selected { activeEar = selected }

        let live = selected != nil
        if hasLiveActivity != live { hasLiveActivity = live }
    }

    // MARK: Alerts

    func post(_ alert: AlertRequest) {
        // One live banner per module: a module re-posting replaces itself
        // rather than stacking up behind its own earlier banner.
        alerts.removeAll { $0.moduleID == alert.moduleID }
        alerts.append(alert)
        recomputeAlert()
    }

    func dismissAlert() {
        if let active = activeAlert {
            alerts.removeAll { $0.id == active.id }
        }
        recomputeAlert()
    }

    func dismissAlerts(from moduleID: String) {
        alerts.removeAll { $0.moduleID == moduleID }
        recomputeAlert()
    }

    private func recomputeAlert() {
        let now = Date()
        alerts = AlertQueueLogic.pruned(alerts, at: now)
        let next = AlertQueueLogic.active(in: alerts, at: now)
        if activeAlert != next { activeAlert = next }

        alertTimer?.invalidate()
        alertTimer = nil
        guard let soonest = alerts.map(\.expiresAt).min() else { return }

        // Springs have no completion callback on macOS 13 and neither does an
        // expiry, so the queue is re-evaluated on a timer aimed at the next one.
        let delay = max(0.05, soonest.timeIntervalSince(now))
        alertTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            Task { @MainActor [weak self] in self?.recomputeAlert() }
        }
    }
}
```

- [ ] **Step 5: Build**

```bash
xcodebuild -scheme NotchNotch -configuration Debug -derivedDataPath build/DerivedData build
```

Expected: `BUILD SUCCEEDED`. The registry is not wired to anything yet, so the app's behaviour is unchanged.

- [ ] **Step 6: Commit**

```bash
git add NotchNotch/Modules/NotchModule.swift NotchNotch/Modules/ModuleRegistry.swift \
        NotchNotch/Support/Log.swift NotchNotch/App/NotchConfiguration.swift \
        NotchNotch.xcodeproj/project.pbxproj
git commit -m "feat(modules): add NotchModule protocol and ModuleRegistry"
```

---

## Task 5: Built-in module adapters

**Files:**
- Create: `NotchNotch/Modules/BuiltIn/OverviewModule.swift`
- Create: `NotchNotch/Modules/BuiltIn/WeatherModule.swift`
- Create: `NotchNotch/Modules/BuiltIn/ShelfModule.swift`
- Create: `NotchNotch/Modules/BuiltIn/ClipboardModule.swift`
- Create: `NotchNotch/Modules/BuiltIn/AgentModule.swift`
- Create: `NotchNotch/Modules/BuiltIn/ScheduleModule.swift`
- Modify: `NotchNotch/Notch/NotchWindowController.swift`

**Interfaces:**
- Consumes: `NotchModule`, `ModuleRegistry` (Task 4); `EarState` (Task 1); `AlertRequest` (Task 2).
- Produces: six classes named as their files. `OverviewModule(media:schedule:)`, `ShelfModule(shelf:)` take the controllers `NotchWindowController` injects; the rest use `.shared` singletons.

Every adapter is a wrapper. **Do not modify the card views or controllers.**

- [ ] **Step 1: Write `OverviewModule.swift`**

The card body is lifted verbatim from `NotchPanelView.overviewContent`.

```swift
//
//  OverviewModule.swift
//  NotchNotch
//

import SwiftUI
import Combine

@MainActor
final class OverviewModule: NotchModule {
    let id = ModuleOrdering.pinnedFirstID
    var title: String { L10n.tr(.tabOverview) }
    let iconName = "square.grid.2x2.fill"
    /// The panel resets here on collapse, so it must always be reachable.
    let canBeDisabled = false

    private let media: NowPlayingController
    private let schedule: ScheduleController

    init(media: NowPlayingController, schedule: ScheduleController) {
        self.media = media
        self.schedule = schedule
    }

    func cardView() -> AnyView {
        AnyView(OverviewCardView(media: media, schedule: schedule))
    }
}

/// Extracted from NotchPanelView.overviewContent unchanged, so that Overview is
/// a module like any other rather than a special case inside the panel.
private struct OverviewCardView: View {
    @ObservedObject var media: NowPlayingController
    @ObservedObject var schedule: ScheduleController

    var body: some View {
        HStack(spacing: 10) {
            let track = media.nowPlaying ?? NowPlaying(
                title: "", artist: "", album: "", isPlaying: false,
                duration: 0, reportedElapsed: 0, reportedAt: .now, playbackRate: 0
            )
            NowPlayingView(
                track: track,
                authorization: media.authorization,
                onRequestAuthorization: { media.requestAuthorization() }
            ) { media.send($0) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            ScheduleTimelineCardView(schedule: schedule)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

- [ ] **Step 2: Write `WeatherModule.swift`**

```swift
//
//  WeatherModule.swift
//  NotchNotch
//

import SwiftUI
import Combine

@MainActor
final class WeatherModule: NotchModule {
    let id = "builtin.weather"
    var title: String { L10n.tr(.tabWeather) }
    let iconName = "cloud.sun.fill"

    private let weather = WeatherController.shared

    func cardView() -> AnyView { AnyView(WeatherCardView()) }

    var earStatePublisher: AnyPublisher<EarState?, Never> {
        Publishers.CombineLatest3(
            weather.$currentSnapshot,
            weather.$isEnabled,
            weather.$showInEars
        )
        .map { [weak weather] snapshot, isEnabled, showInEars -> EarState? in
            guard let weather, isEnabled, showInEars, snapshot != nil else { return nil }
            return EarState(
                leading: .icon(symbol: weather.currentSymbolName,
                               tint: .primary,
                               fill: .whiteMuted),
                trailing: .text(weather.formattedCurrentTemperature ?? "", tint: .textPrimary),
                priority: NotchConfiguration.earPriorityWeather
            )
        }
        .eraseToAnyPublisher()
    }
}
```

- [ ] **Step 3: Write `ShelfModule.swift`**

```swift
//
//  ShelfModule.swift
//  NotchNotch
//

import SwiftUI
import Combine

@MainActor
final class ShelfModule: NotchModule {
    let id = "builtin.shelf"
    var title: String { L10n.tr(.tabShelf) }
    let iconName = "folder.fill"

    private let shelf: ShelfController

    init(shelf: ShelfController) { self.shelf = shelf }

    var badge: String? { shelf.items.isEmpty ? nil : "\(shelf.items.count)" }

    func cardView() -> AnyView { AnyView(DropShelfView(shelf: shelf)) }
}
```

- [ ] **Step 4: Write `ClipboardModule.swift`**

`ClipboardCardView` takes an `isActive` flag, so the module reads the registry's selection to preserve today's behaviour.

```swift
//
//  ClipboardModule.swift
//  NotchNotch
//

import SwiftUI
import Combine

@MainActor
final class ClipboardModule: NotchModule {
    let id = "builtin.clipboard"
    var title: String { L10n.tr(.tabClipboard) }
    let iconName = "doc.on.doc.fill"

    func cardView() -> AnyView { AnyView(ClipboardCardHost(moduleID: id)) }
}

/// ClipboardCardView wants to know whether it is the visible tab. Reading that
/// from the registry keeps the flag correct without the panel special-casing it.
private struct ClipboardCardHost: View {
    let moduleID: String
    @ObservedObject private var registry = ModuleRegistry.shared

    var body: some View {
        ClipboardCardView(isActive: registry.activeModuleID == moduleID)
    }
}
```

- [ ] **Step 5: Write `AgentModule.swift`**

Ear and alert only — no tab card, matching today's UI.

```swift
//
//  AgentModule.swift
//  NotchNotch
//

import SwiftUI
import Combine

@MainActor
final class AgentModule: NotchModule {
    let id = "builtin.agent"
    var title: String { "Agent" }
    let iconName = "sparkles"
    let providesCard = false
    let canBeDisabled = false

    private let agent = AgentHarnessController.shared
    private var cancellables = Set<AnyCancellable>()

    init() { observeAlerts() }

    var earStatePublisher: AnyPublisher<EarState?, Never> {
        agent.$activeSession
            .map { session -> EarState? in
                guard let session else { return nil }
                let priority = NotchConfiguration.earPriorityAgent
                switch session.state {
                case .waitingUser:
                    return EarState(
                        leading: .icon(symbol: "exclamationmark.bubble.fill",
                                       tint: .primary, fill: .primaryMuted),
                        trailing: .badge("REPLY", tint: .primary, fill: .primaryMuted),
                        priority: priority)
                case .waitingSubagent:
                    return EarState(
                        leading: .icon(symbol: "arrow.triangle.branch",
                                       tint: .chart3, fill: .chart3Muted),
                        trailing: .badge("SUB", tint: .chart3, fill: .chart3Muted),
                        priority: priority)
                case .working:
                    return EarState(
                        leading: .icon(symbol: "sparkles", tint: .info, fill: .infoMuted),
                        trailing: .spinner(tint: .info, track: .borderStrong),
                        priority: priority)
                default:
                    return nil
                }
            }
            .eraseToAnyPublisher()
    }

    private func observeAlerts() {
        agent.$currentAlert
            .receive(on: DispatchQueue.main)
            .sink { alert in
                guard let alert else {
                    ModuleRegistry.shared.dismissAlerts(from: "builtin.agent")
                    return
                }
                ModuleRegistry.shared.post(AlertRequest(
                    moduleID: "builtin.agent",
                    icon: alert.state.iconName,
                    tint: .info,
                    title: alert.agent,
                    badge: alert.state.displayName,
                    action: .focusAgentSession,
                    duration: NotchConfiguration.moduleAlertDuration,
                    priority: NotchConfiguration.alertPriorityAgent,
                    postedAt: Date()))
            }
            .store(in: &cancellables)
    }
}
```

**Check the exact case names in `Agent/AgentModels.swift` before writing this.** They are inferred
here from `AgentHarnessController.isWaitingUser` / `.isWaitingSubagent` / `.isWorking` and from
`activeSession?.state == .working` in `NotchWindowController:93`, but only `.working` is confirmed by
a direct comparison in existing code. If any case is spelled differently, use the real spelling — do
not add a computed alias to make this snippet compile. Cases beyond these are already covered by the
`default: return nil` arm; do not widen it speculatively.

- [ ] **Step 6: Write `ScheduleModule.swift`**

```swift
//
//  ScheduleModule.swift
//  NotchNotch
//

import SwiftUI
import Combine

@MainActor
final class ScheduleModule: NotchModule {
    let id = "builtin.schedule"
    var title: String { "Schedule" }
    let iconName = "calendar"
    let providesCard = false
    let canBeDisabled = false

    private let schedule = ScheduleController.shared
    private var cancellables = Set<AnyCancellable>()

    init() { observeAlerts() }

    var earStatePublisher: AnyPublisher<EarState?, Never> {
        Publishers.CombineLatest(schedule.$hasActiveEvent, schedule.$progress)
            .map { hasActiveEvent, progress -> EarState? in
                guard hasActiveEvent else { return nil }
                return EarState(
                    leading: .icon(symbol: "calendar", tint: .primary, fill: .primaryMuted),
                    trailing: .ring(progress: progress, tint: .primary, track: .primaryMuted),
                    priority: NotchConfiguration.earPrioritySchedule)
            }
            .eraseToAnyPublisher()
    }

    private func observeAlerts() {
        schedule.$activeAlert
            .receive(on: DispatchQueue.main)
            .sink { alert in
                guard let alert else {
                    ModuleRegistry.shared.dismissAlerts(from: "builtin.schedule")
                    return
                }
                ModuleRegistry.shared.post(AlertRequest(
                    moduleID: "builtin.schedule",
                    icon: alert.iconName,
                    tint: .primary,
                    title: alert.title,
                    badge: alert.badgeText,
                    action: .expandPanel,
                    duration: NotchConfiguration.moduleAlertDuration,
                    priority: NotchConfiguration.alertPrioritySchedule,
                    postedAt: Date()))
            }
            .store(in: &cancellables)
    }
}
```

If `ScheduleController.progress` is not `@Published`, publish it — or, if it is derived, replace the `CombineLatest` with `schedule.objectWillChange.map { [weak schedule] _ in … }`. Check before writing; do not assume.

- [ ] **Step 7: Register the modules in `NotchWindowController`**

In `NotchWindowController.start()`, immediately before the existing `observeLiveActivities()` call at line 57:

```swift
        registerModules()
```

And add the method:

```swift
    /// Registration order is the default tab order for a fresh install; the
    /// user's saved order overrides it from then on.
    private func registerModules() {
        let registry = ModuleRegistry.shared
        registry.register(OverviewModule(media: nowPlaying, schedule: schedule))
        registry.register(WeatherModule())
        registry.register(ShelfModule(shelf: shelf))
        registry.register(ClipboardModule())
        registry.register(AgentModule())
        registry.register(ScheduleModule())
        registry.finishRegistration()
    }
```

Hold the ear/alert-only modules in a property so they are not deallocated — `register(_:)` stores them in the registry's `modules` array, which retains them, so no extra property is needed. Confirm this by checking that the agent ear still updates in Step 8.

- [ ] **Step 8: Verify registration at runtime**

```bash
xcodebuild -scheme NotchNotch -configuration Debug -derivedDataPath build/DerivedData build
pkill -f NotchNotch; sleep 1
build/DerivedData/Build/Products/Debug/NotchNotch.app/Contents/MacOS/NotchNotch >/dev/null 2>&1 &
sleep 3
log show --last 30s --predicate 'subsystem == "co.jianyuelab.NotchNotch" AND category == "modules"' --info
```

Expected: `registered 6 modules, 4 visible`.

Then confirm the agent ear publisher fires, using the HTTP server rather than synthetic input (this shell is not Accessibility-trusted, so hover cannot be driven from the terminal):

```bash
curl -s -X POST localhost:7823/event \
  -H 'Content-Type: application/json' \
  -d '{"state":"working","agent":"claude","session_id":"plan-test"}'
```

The panel is not wired to the registry yet, so nothing changes visually — this step only proves registration and the publishers are alive. Confirm no errors appear in the `modules` category.

- [ ] **Step 9: Commit**

```bash
git add NotchNotch/Modules/BuiltIn NotchNotch/Notch/NotchWindowController.swift \
        NotchNotch.xcodeproj/project.pbxproj
git commit -m "feat(modules): add built-in module adapters for all six features"
```

---

## Task 6: Registry-driven tab bar and content row

**Files:**
- Modify: `NotchNotch/Views/NotchPanelView.swift` (remove `NotchActiveTab`, lines 12–27; rewrite `expandedContent`, `tabSlot`, `topBar`, `circleIconButton`; delete `overviewContent`)

**Interfaces:**
- Consumes: `ModuleRegistry.shared` (Task 4), the six adapters (Task 5).
- Produces: no new API. `NotchPanelView` gains `@ObservedObject private var registry = ModuleRegistry.shared` and loses `@State private var activeTab`.

- [ ] **Step 1: Capture the "before" screenshot**

```bash
pkill -f NotchNotch; sleep 1
defaults write co.jianyuelab.NotchNotch co.jianyuelab.NotchNotch.agentMonitoringEnabled -bool false
build/DerivedData/Build/Products/Debug/NotchNotch.app/Contents/MacOS/NotchNotch >/dev/null 2>&1 &
sleep 3
swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(
  Notification.Name("co.jianyuelab.NotchNotch.expand"), object: nil, deliverImmediately: true)'
sleep 1
screencapture -x .temp/before_tabs.png
```

Agent banners take over the panel and would interrupt the capture, which is why monitoring is disabled first. It is restored in Step 7.

- [ ] **Step 2: Delete the `NotchActiveTab` enum**

Remove lines 12–27 of `NotchNotch/Views/NotchPanelView.swift` entirely. Replace the `@State private var activeTab: NotchActiveTab = .overview` declaration with:

```swift
    @ObservedObject private var registry = ModuleRegistry.shared
```

- [ ] **Step 3: Replace every `activeTab` reference**

There are assignments in `onReceive(machine.$state)`, the `selectTab` handler, the three file-drag handlers and `onChange(of: isDraggingFile)`. Rewrite them as registry calls:

```swift
        .onReceive(machine.$state) { state in
            if state == .collapsed {
                isDraggingFile = false
                registry.resetToOverview()
            } else if state == .expanding {
                if !isDraggingFile {
                    registry.resetToOverview()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: Notification.Name("co.jianyuelab.NotchNotch.selectTab"))) { notif in
            guard let tabName = notif.object as? String else { return }
            if tabName == "settings" {
                SettingsWindowController.shared.show()
                return
            }
            withAnimation(.easeInOut(duration: 0.12)) {
                // Accepts both the documented legacy names and raw module ids,
                // so plugins are addressable through the same notification.
                if !registry.selectLegacy(tabName: tabName) {
                    registry.select(moduleID: tabName)
                }
            }
        }
```

For the three drag/drop sites, replace `activeTab = .shelf` with:

```swift
                registry.select(moduleID: "builtin.shelf")
```

- [ ] **Step 4: Rewrite `expandedContent` and `tabSlot`**

```swift
    @ViewBuilder
    private var expandedContent: some View {
        VStack(spacing: 7) {
            topBar

            // Every tab is pinned to its own content-row slot rather than being
            // sized by the ZStack. The ZStack would otherwise adopt the tallest
            // child's minimum height and centre *all* of them on it, so one
            // oversized card silently pushed every other tab out of the panel.
            ZStack {
                ForEach(registry.visibleModules, id: \.id) { module in
                    tabSlot(module.id) { module.cardView() }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: NotchConfiguration.expandedContentRowHeight)
            .clipped()
        }
        .padding(.horizontal, 14)
        .padding(.top, 7)
        .padding(.bottom, 14)
        .frame(width: machine.layout.expandedSize.width,
               height: machine.layout.expandedSize.height,
               alignment: .top)
        .foregroundStyle(.white)
        .clipped()
    }

    /// One tab's slot in the content row: fixed to the row height so a card that
    /// refuses to compress cannot resize the shared ZStack, and clipped so it
    /// cannot bleed into the top bar or past the bottom of the panel.
    @ViewBuilder
    private func tabSlot<Content: View>(
        _ moduleID: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .frame(height: NotchConfiguration.expandedContentRowHeight)
            .clipped()
            .opacity(registry.activeModuleID == moduleID ? 1 : 0)
            .allowsHitTesting(registry.activeModuleID == moduleID)
    }
```

- [ ] **Step 5: Rewrite the tab button row in `topBar`**

Replace the four hardcoded `circleIconButton(tab:icon:)` calls with:

```swift
            HStack(spacing: 6) {
                ForEach(registry.visibleModules, id: \.id) { module in
                    circleIconButton(module: module)
                }
                Spacer(minLength: 0)
            }
            .frame(width: earWidth, alignment: .leading)
```

and rewrite the button itself:

```swift
    private func circleIconButton(module: any NotchModule) -> some View {
        let isSelected = registry.activeModuleID == module.id
        let badge = module.badge
        return Button {
            withAnimation(.easeInOut(duration: 0.12)) {
                registry.select(moduleID: module.id)
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                Circle()
                    .fill(isSelected ? JYLTheme.neutral700 : JYLTheme.neutral800)
                    .overlay(
                        Circle()
                            .strokeBorder(isSelected ? Color.white.opacity(0.18) : Color.clear,
                                          lineWidth: 0.5)
                    )
                    .frame(width: 26, height: 26)

                Image(systemName: module.iconName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(isSelected ? JYLTheme.textPrimary : JYLTheme.textSecondary)
                    .frame(width: 26, height: 26)

                if let badge {
                    Text(badge)
                        .font(.system(size: 7.5, weight: .bold, design: .rounded))
                        .foregroundStyle(JYLTheme.textPrimary)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 0.5)
                        .background(Capsule().fill(JYLTheme.primary))
                        .offset(x: 3, y: -2)
                }
            }
        }
        .buttonStyle(TabButtonStyle())
        .help(module.title)
    }
```

- [ ] **Step 6: Delete `overviewContent`**

It now lives in `OverviewModule.swift`. Remove the whole `// MARK: - Overview Content` section from `NotchPanelView`.

- [ ] **Step 7: Verify visually and by notification**

```bash
xcodebuild -scheme NotchNotch -configuration Debug -derivedDataPath build/DerivedData build
pkill -f NotchNotch; sleep 1
build/DerivedData/Build/Products/Debug/NotchNotch.app/Contents/MacOS/NotchNotch >/dev/null 2>&1 &
sleep 3
swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(
  Notification.Name("co.jianyuelab.NotchNotch.expand"), object: nil, deliverImmediately: true)'
sleep 1
screencapture -x .temp/after_tabs.png

for tab in overview weather shelf clipboard; do
  swift -e "import Foundation; DistributedNotificationCenter.default().postNotificationName(
    Notification.Name(\"co.jianyuelab.NotchNotch.selectTab\"), object: \"$tab\",
    deliverImmediately: true)"
  sleep 1
  screencapture -x .temp/tab_$tab.png
done

defaults delete co.jianyuelab.NotchNotch co.jianyuelab.NotchNotch.agentMonitoringEnabled
```

Open `.temp/before_tabs.png` and `.temp/after_tabs.png` and compare them directly. **They must be identical** — four tab buttons in the same order, same icons, same Overview content, same 174pt panel with no clipping at either end. Each `tab_*.png` must show the corresponding card.

If they differ, stop and fix before continuing. This is the task most likely to regress the layout work in commits `7250155`, `3d1b94e` and `b96ed69`.

- [ ] **Step 8: Commit**

```bash
git add NotchNotch/Views/NotchPanelView.swift
git commit -m "refactor(modules): drive the tab bar and content row from the registry"
```

---

## Task 7: Registry-driven ears

**Files:**
- Create: `NotchNotch/Views/EarView.swift`
- Modify: `NotchNotch/Views/NotchPanelView.swift` (replace `compactContent`, `compactLeftEar`, `compactRightEar`, `hasLiveActivity`, `isMusicPlaying`, `isAgentActive`, `isWeatherActive`)
- Modify: `NotchNotch/Modules/BuiltIn/OverviewModule.swift` (add the music ear)

**Interfaces:**
- Consumes: `EarState` (Task 1), `ThemeToken.color` (Task 1), `ModuleRegistry.activeEar` and `.hasLiveActivity` (Task 4).
- Produces: `EarView.Leading(state:)` and `EarView.Trailing(state:)` SwiftUI views.

- [ ] **Step 1: Add the music ear to `OverviewModule`**

Music has no module of its own today; it belongs to Overview, which already owns the media controller.

```swift
    var earStatePublisher: AnyPublisher<EarState?, Never> {
        media.$nowPlaying
            .map { track -> EarState? in
                guard let track, track.isPlaying, track.hasTrack else { return nil }
                let leading: EarState.Leading = {
                    if let art = track.artwork, art.isValid, art.size.width > 0 {
                        return .artwork(art)
                    }
                    return .brandIcon(symbol: "music.note")
                }()
                return EarState(
                    leading: leading,
                    trailing: .gradientRing(progress: track.progress(at: Date()),
                                            from: .chart2, to: .info, track: .borderStrong),
                    priority: NotchConfiguration.earPriorityMusic)
            }
            .eraseToAnyPublisher()
    }
```

The ring progress is sampled when `nowPlaying` republishes rather than at 2 Hz via `TimelineView` as before. If the ring visibly stops advancing between track updates in Step 4, wrap only the ring in a `TimelineView` inside `EarView.Trailing` — do not reintroduce a timer in the module.

- [ ] **Step 2: Write `EarView.swift`**

```swift
//
//  EarView.swift
//  NotchNotch
//
//  Renders one EarState. This is what replaced the two ~65-line if/else chains
//  in NotchPanelView: every ear the app has ever shown is one of these cases,
//  so a new feature — or a plugin — contributes data instead of a new branch.
//
//  Sizes are normalized here on purpose. The original chains used 18/19/20pt
//  rings and 21/22pt chips for what are visually the same component.
//

import SwiftUI

enum EarView {

    static let chipSize: CGFloat = 22
    static let chipRadius: CGFloat = 6
    static let ringSize: CGFloat = 20
    static let ringWidth: CGFloat = 3.0

    struct Leading: View {
        let state: EarState.Leading

        var body: some View {
            switch state {
            case .none:
                EmptyView()

            case let .icon(symbol, tint, fill):
                ZStack {
                    RoundedRectangle(cornerRadius: chipRadius, style: .continuous)
                        .fill(fill.color)
                        .frame(width: chipSize, height: chipSize)
                    Image(systemName: symbol)
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(tint.color)
                }

            case let .brandIcon(symbol):
                ZStack {
                    RoundedRectangle(cornerRadius: chipRadius, style: .continuous)
                        .fill(JYLTheme.brandGradientDiagonal)
                        .frame(width: chipSize, height: chipSize)
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(JYLTheme.textPrimary)
                }

            case let .artwork(image):
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: chipSize, height: chipSize)
                    .clipShape(RoundedRectangle(cornerRadius: chipRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: chipRadius, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                    )
            }
        }

        private var chipSize: CGFloat { EarView.chipSize }
        private var chipRadius: CGFloat { EarView.chipRadius }
    }

    struct Trailing: View {
        let state: EarState.Trailing

        var body: some View {
            switch state {
            case .none:
                EmptyView()

            case let .ring(progress, tint, track):
                ring(progress: progress, track: track) {
                    AnyShapeStyle(tint.color)
                }

            case let .gradientRing(progress, from, to, track):
                ring(progress: progress, track: track) {
                    AnyShapeStyle(LinearGradient(colors: [from.color, to.color],
                                                 startPoint: .topLeading,
                                                 endPoint: .bottomTrailing))
                }

            case let .spinner(tint, track):
                TimelineView(.animation) { timeline in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    let angle = (time.truncatingRemainder(dividingBy: 1.5)) / 1.5 * 360
                    ZStack {
                        Circle()
                            .stroke(track.color, lineWidth: EarView.ringWidth)
                            .frame(width: EarView.ringSize, height: EarView.ringSize)
                        Circle()
                            .trim(from: 0, to: 0.35)
                            .stroke(tint.color,
                                    style: StrokeStyle(lineWidth: EarView.ringWidth, lineCap: .round))
                            .rotationEffect(.degrees(angle))
                            .frame(width: EarView.ringSize, height: EarView.ringSize)
                    }
                }

            case let .text(value, tint):
                Text(value)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .foregroundStyle(tint.color)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(ThemeToken.whiteMuted.color))

            case let .badge(value, tint, fill):
                Text(value)
                    .font(.system(size: 7.5, weight: .black, design: .rounded))
                    .lineLimit(1)
                    .foregroundStyle(tint.color)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(fill.color))
            }
        }

        @ViewBuilder
        private func ring(progress: Double,
                          track: ThemeToken,
                          style: () -> AnyShapeStyle) -> some View {
            ZStack {
                Circle()
                    .stroke(track.color, lineWidth: EarView.ringWidth)
                    .frame(width: EarView.ringSize, height: EarView.ringSize)
                Circle()
                    .trim(from: 0, to: max(0.04, min(1.0, progress)))
                    .stroke(style(),
                            style: StrokeStyle(lineWidth: EarView.ringWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: EarView.ringSize, height: EarView.ringSize)
            }
        }
    }
}
```

- [ ] **Step 3: Replace the ear chains in `NotchPanelView`**

Delete `compactLeftEar`, `compactRightEar`, `isMusicPlaying`, `isAgentActive` and `isWeatherActive` entirely. Replace `hasLiveActivity` and `compactContent` with:

```swift
    private var hasLiveActivity: Bool { registry.hasLiveActivity }

    @ViewBuilder
    private var compactContent: some View {
        if let ear = registry.activeEar {
            let notchWidth = machine.layout.geometry.notchRect.width
            let earWidth = NotchConfiguration.compactWidthExtension / 2

            HStack(spacing: 0) {
                EarView.Leading(state: ear.state.leading)
                    .frame(width: earWidth)

                // Center: clear notch hardware area (fixed rigid cutout)
                Color.clear
                    .frame(width: notchWidth, height: machine.layout.collapsedSize.height)

                EarView.Trailing(state: ear.state.trailing)
                    .frame(width: earWidth)
            }
            .frame(width: collapsedWidth, height: machine.layout.collapsedSize.height)
        }
    }
```

Remove the now-unused `@ObservedObject` properties from `NotchPanelView` **only if nothing else references them** — `agentController` is still used by `agentAlertContent` and the top-bar badge, and `schedule` is still passed to modules. Compile and let the warnings tell you.

- [ ] **Step 4: Verify each ear**

```bash
xcodebuild -scheme NotchNotch -configuration Debug -derivedDataPath build/DerivedData build
pkill -f NotchNotch; sleep 1
build/DerivedData/Build/Products/Debug/NotchNotch.app/Contents/MacOS/NotchNotch >/dev/null 2>&1 &
sleep 3

# Agent ear — working (icon + spinner)
curl -s -X POST localhost:7823/event -H 'Content-Type: application/json' \
  -d '{"state":"working","agent":"claude","session_id":"ear-test"}'
sleep 1; screencapture -x .temp/ear_agent_working.png

# Agent ear — waiting user (icon + REPLY badge)
curl -s -X POST localhost:7823/event -H 'Content-Type: application/json' \
  -d '{"state":"waitinguser","agent":"claude","session_id":"ear-test"}'
sleep 1; screencapture -x .temp/ear_agent_reply.png

# Idle — the pill must narrow back to bare notch width
curl -s -X POST localhost:7823/event -H 'Content-Type: application/json' \
  -d '{"state":"idle","agent":"claude","session_id":"ear-test"}'
sleep 1; screencapture -x .temp/ear_idle.png
```

Expected: the working shot shows a blue `sparkles` chip on the left and a rotating arc on the right; the reply shot shows an amber bubble chip and a `REPLY` capsule; the idle shot shows a bare notch with no ears and a narrower pill.

Then play something in Music or Spotify and capture `.temp/ear_music.png` — artwork on the left, gradient progress ring on the right, and the ring must advance over ~10 seconds. Enable Weather with "show in ears" and capture `.temp/ear_weather.png`.

- [ ] **Step 5: Sign off the accepted visual deltas**

Compare `.temp/ear_*.png` against `.temp/before_tabs.png` and the pre-change app. Ring and chip sizes are now uniform by design (see *Accepted visual deltas*). Confirm the change reads as intentional rather than broken. If any ear looks wrong beyond the documented normalization, fix it before committing.

- [ ] **Step 6: Commit**

```bash
git add NotchNotch/Views/EarView.swift NotchNotch/Views/NotchPanelView.swift \
        NotchNotch/Modules/BuiltIn/OverviewModule.swift NotchNotch.xcodeproj/project.pbxproj
git commit -m "refactor(modules): render collapsed ears from EarState instead of if/else chains"
```

---

## Task 8: Registry-driven alert banner

**Files:**
- Modify: `NotchNotch/Views/NotchPanelView.swift` (replace `scheduleAlertContent` and `agentAlertContent` with one `alertBarContent`)

**Interfaces:**
- Consumes: `AlertRequest`, `AlertAction` (Task 2), `ModuleRegistry.activeAlert` (Task 4).
- Produces: no new API.

- [ ] **Step 1: Replace the two alert branches with one**

In `panel`, replace the `isShowingScheduleAlert` / `isShowingAgentAlert` branches with:

```swift
            if let alert = registry.activeAlert, !isOpen {
                alertBarContent(alert)
                    .transition(.opacity)
            } else if isShowingHUD {
```

and replace the two computed flags with one:

```swift
    private var isShowingAlert: Bool { registry.activeAlert != nil && !isOpen }
```

Update every use of `isShowingAgentAlert` / `isShowingScheduleAlert` in `bodySize`, `notchShape`, the `.animation` modifiers and the `.shadow` modifier to the single `isShowingAlert`. The volume/brightness `isShowingHUD` branch is untouched — it is system state, not a module, and its bar layout differs.

- [ ] **Step 2: Write the unified banner**

The structure is lifted from the existing two, which were already identical apart from their action.
`perform(_:)` calls `NSWorkspace`, so add `import AppKit` at the top of `NotchPanelView.swift` if it
is not already there — SwiftUI does not reliably re-export it.

```swift
    // MARK: - Module Alert Bar

    private func alertBarContent(_ alert: AlertRequest) -> some View {
        let notchWidth = machine.layout.geometry.notchRect.width

        return HStack(spacing: 0) {
            // Left ear (completely outside physical notch)
            HStack(spacing: 7) {
                Image(systemName: alert.icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(alert.tint.color)
                    .frame(width: 18)

                Text(alert.title)
                    .font(.system(size: 12.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.leading, 18)
            .frame(width: hudEarWidth, alignment: .leading)

            // Center: Physical notch cutout exclusion zone
            Color.clear
                .frame(width: notchWidth, height: hudBarHeight)

            // Right ear (completely outside physical notch)
            Button {
                perform(alert.action)
            } label: {
                HStack(spacing: 6) {
                    if let badge = alert.badge {
                        Text(badge)
                            .font(.system(size: 11.5, weight: .bold, design: .rounded))
                            .foregroundStyle(alert.tint.color)
                    }
                    Image(systemName: alert.action == .focusAgentSession
                          ? "arrow.up.forward.app" : "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(JYLTheme.textSecondary)
                }
            }
            .buttonStyle(.plain)
            .padding(.trailing, 18)
            .frame(width: hudEarWidth, alignment: .trailing)
        }
        .frame(width: hudBarWidth, height: hudBarHeight)
        .contentShape(Rectangle())
        .onTapGesture { perform(alert.action) }
    }

    private func perform(_ action: AlertAction) {
        switch action {
        case .none:
            registry.dismissAlert()
        case .focusAgentSession:
            agentController.focusActiveAgent()
            registry.dismissAlert()
        case .expandPanel:
            registry.dismissAlert()
            machine.expandImmediately()
        case let .openModule(id):
            registry.dismissAlert()
            machine.expandImmediately()
            registry.select(moduleID: id)
        case let .openURL(url):
            NSWorkspace.shared.open(url)
            registry.dismissAlert()
        }
    }
```

- [ ] **Step 3: Verify both banners**

```bash
xcodebuild -scheme NotchNotch -configuration Debug -derivedDataPath build/DerivedData build
pkill -f NotchNotch; sleep 1
build/DerivedData/Build/Products/Debug/NotchNotch.app/Contents/MacOS/NotchNotch >/dev/null 2>&1 &
sleep 3
curl -s -X POST localhost:7823/event -H 'Content-Type: application/json' \
  -d '{"state":"waitinguser","agent":"claude","event":"needs reply","session_id":"alert-test"}'
sleep 1; screencapture -x .temp/alert_agent.png
sleep 5; screencapture -x .temp/alert_expired.png
```

Expected: `alert_agent.png` shows the banner with the agent name and an `arrow.up.forward.app` affordance; `alert_expired.png` shows it gone, having retired on the queue's timer rather than a per-feature one. Clicking the banner must still focus the terminal.

Schedule banners need a calendar event within the alert window — if one cannot be arranged during this task, note it in the commit body as verified by code inspection only, and confirm it before the phase is considered done.

- [ ] **Step 4: Commit**

```bash
git add NotchNotch/Views/NotchPanelView.swift
git commit -m "refactor(modules): unify the agent and schedule banners into one alert queue"
```

---

## Task 9: Single-source `hasLiveActivity`

**Files:**
- Modify: `NotchNotch/Notch/NotchWindowController.swift:92-95` (`reload()`) and `:104-130` (`observeLiveActivities()`)

**Interfaces:**
- Consumes: `ModuleRegistry.shared.$hasLiveActivity` (Task 4).
- Produces: no new API. This task **deletes** the duplication `CLAUDE.md` documents.

- [ ] **Step 1: Replace the `CombineLatest4`**

In `observeLiveActivities()`, delete the `weatherPublisher` local and the whole `Publishers.CombineLatest4(...)` chain through its `.store(in: &cancellables)`, and substitute:

```swift
        // One aggregation point, and only one. This used to be a CombineLatest4
        // that had to be kept byte-identical with an inline recomputation in
        // reload(); every new ear feature had to remember to edit both. The
        // registry now owns it, so an ear is contributed rather than wired.
        ModuleRegistry.shared.$hasLiveActivity
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] hasLive in
                self?.stateMachine.updateHasLiveActivity(hasLive)
            }
            .store(in: &cancellables)
```

Leave the two subsequent subscriptions (`SystemMediaHUDController.shared.$isShowing` and `AgentHarnessController.shared.$isShowingAlert`) exactly as they are — they control window ordering, not live activity.

- [ ] **Step 2: Deduplicate `reload()`**

Replace lines 92–95 with:

```swift
        let hasLive = ModuleRegistry.shared.hasLiveActivity
```

- [ ] **Step 3: Verify the pill still widens**

```bash
xcodebuild -scheme NotchNotch -configuration Debug -derivedDataPath build/DerivedData build
pkill -f NotchNotch; sleep 1
build/DerivedData/Build/Products/Debug/NotchNotch.app/Contents/MacOS/NotchNotch >/dev/null 2>&1 &
sleep 3
screencapture -x .temp/pill_idle.png
curl -s -X POST localhost:7823/event -H 'Content-Type: application/json' \
  -d '{"state":"working","agent":"claude","session_id":"pill-test"}'
sleep 1; screencapture -x .temp/pill_live.png
curl -s -X POST localhost:7823/event -H 'Content-Type: application/json' \
  -d '{"state":"idle","agent":"claude","session_id":"pill-test"}'
sleep 1; screencapture -x .temp/pill_back.png
```

Expected: `pill_live.png` is wider than `pill_idle.png` by `NotchConfiguration.compactWidthExtension` (72pt) and has rounded collapsed corners; `pill_back.png` matches `pill_idle.png`.

Then exercise `reload()` from the menu bar item ("Reload") while an agent is working, and confirm the pill stays wide — that is the exact bug the old duplication caused when the two computations drifted.

- [ ] **Step 4: Commit**

```bash
git add NotchNotch/Notch/NotchWindowController.swift
git commit -m "refactor(modules): make the registry the single source of hasLiveActivity"
```

---

## Task 10: Settings — reorder and hide tabs

**Files:**
- Create: `NotchNotch/Views/ModulesSettingsCard.swift`
- Modify: `NotchNotch/Views/SettingsView.swift:580` (append the card to `generalSection`'s `VStack`)
- Modify: `NotchNotch/Localization/L10n.swift` (three keys, both tables)

**Interfaces:**
- Consumes: `ModuleRegistry.shared` (Task 4).
- Produces: `ModulesSettingsCard` — a `View` with no parameters.

- [ ] **Step 1: Add the localization keys**

In `L10nKey`, after the navigation-tab cases:

```swift
    // MARK: - Settings: Modules
    case settingsModulesTitle
    case settingsModulesDesc
    case settingsModulesPinned
```

In the Chinese table, alongside `.tabClipboard`:

```swift
        .settingsModulesTitle: "标签页",
        .settingsModulesDesc: "调整顺序，或关闭不需要的标签页。",
        .settingsModulesPinned: "固定",
```

In the English table:

```swift
        .settingsModulesTitle: "Tabs",
        .settingsModulesDesc: "Reorder them, or switch off tabs you don't need.",
        .settingsModulesPinned: "Pinned",
```

- [ ] **Step 2: Write `ModulesSettingsCard.swift`**

```swift
//
//  ModulesSettingsCard.swift
//  NotchNotch
//
//  Reorder and hide tabs. Built-ins and plugins appear in the same list
//  because they are the same kind of thing to the registry.
//

import SwiftUI

struct ModulesSettingsCard: View {
    @ObservedObject private var registry = ModuleRegistry.shared
    @ObservedObject private var loc = LocalizationManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(JYLTheme.neutral800)
                        .frame(width: 32, height: 32)
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(JYLTheme.primary)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.tr(.settingsModulesTitle))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(JYLTheme.textPrimary)

                    Text(L10n.tr(.settingsModulesDesc))
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(JYLTheme.textSecondary)
                }

                Spacer()
            }

            VStack(spacing: 6) {
                ForEach(registry.allCardModules, id: \.id) { module in
                    HStack(spacing: 10) {
                        Image(systemName: module.iconName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(JYLTheme.textSecondary)
                            .frame(width: 18)

                        Text(module.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(JYLTheme.textPrimary)

                        Spacer()

                        HStack(spacing: 2) {
                            moveButton(module.id, .up, "chevron.up")
                            moveButton(module.id, .down, "chevron.down")
                        }

                        if module.canBeDisabled {
                            Toggle("", isOn: Binding(
                                get: { registry.isEnabled(module.id) },
                                set: { registry.setEnabled($0, for: module.id) }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                        } else {
                            Text(L10n.tr(.settingsModulesPinned))
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(JYLTheme.textMuted)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(JYLTheme.neutral800))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(JYLTheme.neutral900.opacity(0.6))
                    )
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(JYLTheme.neutral900.opacity(0.7))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(JYLTheme.border.opacity(0.6), lineWidth: 0.8)
                )
        )
    }

    private func moveButton(_ id: String,
                            _ direction: ModuleRegistry.MoveDirection,
                            _ symbol: String) -> some View {
        let enabled = registry.canMove(id: id, direction: direction)
        return Button {
            withAnimation(.easeInOut(duration: 0.12)) {
                registry.move(id: id, direction: direction)
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(enabled ? JYLTheme.textSecondary : JYLTheme.textMuted.opacity(0.4))
                .frame(width: 18, height: 16)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
```

- [ ] **Step 3: Expose `allCardModules` on the registry**

`visibleModules` excludes disabled ones, so Settings needs the unfiltered list to offer them back. Add to `ModuleRegistry`:

```swift
    /// Every card-providing module including hidden ones — Settings needs to
    /// show what you turned off in order to let you turn it back on.
    var allCardModules: [any NotchModule] {
        let cards = modules.filter(\.providesCard)
        let order = ModuleOrdering.resolve(
            available: cards.map(\.id),
            persistedOrder: UserDefaults.standard.stringArray(forKey: orderKey) ?? [],
            disabled: []
        )
        return order.compactMap { id in cards.first { $0.id == id } }
    }
```

- [ ] **Step 4: Insert the card into the General tab**

In `SettingsView.generalSection`, immediately before the closing brace of the outer `VStack(spacing: 14)` at line 580:

```swift
            ModulesSettingsCard()
```

- [ ] **Step 5: Verify**

```bash
xcodebuild -scheme NotchNotch -configuration Debug -derivedDataPath build/DerivedData build
pkill -f NotchNotch; sleep 1
build/DerivedData/Build/Products/Debug/NotchNotch.app/Contents/MacOS/NotchNotch >/dev/null 2>&1 &
sleep 3
swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(
  Notification.Name("co.jianyuelab.NotchNotch.selectTab"), object: "settings",
  deliverImmediately: true)'
sleep 2; screencapture -x .temp/settings_modules.png
```

Expected: the General tab shows four rows — Overview marked *Pinned*, the other three with switches
and a pair of chevrons each. Overview's up-chevron and the last row's down-chevron are dimmed and
inert, because nothing may move above the pinned first slot or below the end.

Move Weather down one, expand the panel, and confirm the tab buttons reorder to match.

Turn Clipboard off, then:

```bash
swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(
  Notification.Name("co.jianyuelab.NotchNotch.expand"), object: nil, deliverImmediately: true)'
sleep 1; screencapture -x .temp/tabs_clipboard_hidden.png
```

Expected: three tab buttons. Relaunch the app and confirm the choice persisted. Switch the interface language to 中文 and confirm the card's strings change. Turn Clipboard back on before finishing.

- [ ] **Step 6: Commit**

```bash
git add NotchNotch/Views/ModulesSettingsCard.swift NotchNotch/Views/SettingsView.swift \
        NotchNotch/Localization/L10n.swift NotchNotch/Modules/ModuleRegistry.swift \
        NotchNotch.xcodeproj/project.pbxproj
git commit -m "feat(settings): add tab reordering and visibility controls"
```

---

## Task 11: Documentation and version

**Files:**
- Modify: `CLAUDE.md`
- Modify: `NotchNotch.xcodeproj/project.pbxproj` (`MARKETING_VERSION`, **both** Debug and Release)

**Interfaces:**
- Consumes: everything above.
- Produces: nothing executable.

- [ ] **Step 1: Correct the live-activity section of `CLAUDE.md`**

The section headed *"Live activity → compact width"* is now wrong — it instructs the reader to edit two places that no longer exist. Replace it with:

```markdown
### Live activity → compact width

`ModuleRegistry` is the single aggregation point. Each module publishes an `EarState?` through
`earStatePublisher`; the registry selects the highest-priority live one, publishes
`hasLiveActivity`, and `NotchWindowController` widens the collapsed body by `compactWidthExtension`
in response. Adding a new "ear" feature means contributing an `EarState` from a module — there is no
second site to keep in sync, which there used to be.
```

- [ ] **Step 2: Add a registry section to `CLAUDE.md`**

After *"The Notch/ quartet"*, insert:

```markdown
### The module registry

`Modules/` is how features reach the panel. A `NotchModule` optionally contributes a tab card, a
collapsed ear (`EarState`), and alert banners (`AlertRequest`); `ModuleRegistry` owns ordering,
enablement, ear priority selection and the alert queue. The six built-ins under `Modules/BuiltIn/`
are thin adapters — the card views and controllers they wrap are unchanged.

The registry publishes **structural** change only. Card views keep observing their own controllers
directly, because routing leaf reactivity through the registry would invalidate the entire panel on
every now-playing tick.

Ears and alerts are *data*, not views, so that a later JS plugin with no live context can still
express one. `EarState`, `AlertRequest`, `EarSelection`, `AlertQueueLogic` and `ModuleOrdering` are
pure and `nonisolated`, which is what makes them checkable by a standalone `swiftc` script.

Tab order and hidden tabs persist under `co.jianyuelab.NotchNotch.moduleOrder` and
`…disabledModules`. `builtin.overview` is pinned first and cannot be hidden, because the panel
resets to it on collapse.
```

- [ ] **Step 3: Note the module ids in the verification section**

In the *Verification* section of `CLAUDE.md`, after the sentence describing `selectTab`, add:

```markdown
`selectTab` also accepts raw module ids (`builtin.weather`, and later `plugin.<id>`) in addition to
the four legacy lowercase names, which continue to work unchanged.
```

- [ ] **Step 4: Bump the version**

Today is 2026-09-13. September or later means `XX = (2026 mod 100) + 1 = 27`. This phase adds a
user-visible capability (hiding and reordering tabs), so the minor bumps: **27.1.1 → 27.2.0**.

```bash
sed -i '' 's/MARKETING_VERSION = 27.1.1;/MARKETING_VERSION = 27.2.0;/g' \
  NotchNotch.xcodeproj/project.pbxproj
grep -c 'MARKETING_VERSION = 27.2.0;' NotchNotch.xcodeproj/project.pbxproj
```

Expected output: `2` — Debug and Release. If it prints anything else, fix both by hand.

- [ ] **Step 5: Full verification pass**

```bash
xcodebuild -scheme NotchNotch -configuration Release -derivedDataPath build/DerivedData build
swiftc -swift-version 6 -o .temp/t_ear/run NotchNotch/Modules/ThemeToken.swift \
  NotchNotch/Modules/EarState.swift .temp/t_ear/main.swift && .temp/t_ear/run
swiftc -swift-version 6 -o .temp/t_alert/run NotchNotch/Modules/ThemeToken.swift \
  NotchNotch/Modules/AlertRequest.swift .temp/t_alert/main.swift && .temp/t_alert/run
swiftc -swift-version 6 -o .temp/t_order/run NotchNotch/Modules/ModuleOrdering.swift \
  .temp/t_order/main.swift && .temp/t_order/run
```

Expected: `BUILD SUCCEEDED` and three `PASS` lines. Report any failure verbatim rather than
summarising it.

- [ ] **Step 6: Commit and clean up**

```bash
git add CLAUDE.md NotchNotch.xcodeproj/project.pbxproj
git commit -m "docs: document the module registry and bump to 27.2.0"
rm -rf .temp
pkill -f NotchNotch
```

---

## Self-Review Notes

**Spec coverage (§2 of the design doc):**

| Spec requirement | Task |
|---|---|
| §2.1 `NotchModule` protocol with `AnyView` erasure | 4 |
| §2.2 Registry publishes structural change only | 4 (documented in the file header), 11 |
| §2.3 `EarState` template covering all six existing ears | 1, 5, 7 |
| §2.3 Priorities seeded to music > agent > schedule > weather | 4 (constants), 5 (use) |
| §2.4 Single-source `hasLiveActivity`, `reload()` deduplicated | 9 |
| §2.5 Alert priority queue; HUD stays separate | 2, 4, 8 |
| §2.6 Tab bar from registry; `tabSlot` invariant preserved | 6 |
| §2.7 `selectTab` legacy vocabulary preserved | 3 (mapping), 6 (wiring) |
| §6 Standalone `.temp/` scripts; `log stream`; screenshots | 1, 2, 3 (scripts); 5–10 (runtime) |
| Overview pinned and non-disableable | 3, 4, 5, 10 |
| Settings module list | 10 |

**Not in this plan, by design:** everything in spec §1 (JS runtime), §3 (capabilities), §4 (package
format and SDK), §5 (plugin lifecycle) and §7 (JIT entitlement, `nn-runtime.js` bundling). Those are
phases 2–6 and get their own plans. Nothing here depends on them.

**Two things the implementer must check rather than assume**, both flagged inline:
`ScheduleController.progress` may not be `@Published` (Task 5, Step 6), and the music ring's progress
sampling changes from a 2 Hz `TimelineView` to `nowPlaying` republication (Task 7, Step 1).
