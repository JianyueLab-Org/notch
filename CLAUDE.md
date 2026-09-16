# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

NotchNotch — a macOS `LSUIElement` agent app (bundle id `co.jianyuelab.NotchNotch`) that draws an
interactive "dynamic island" panel over the MacBook Pro camera housing. Swift 6, SwiftUI + AppKit,
macOS 13.0+, single Xcode target, no package dependencies.

## Commands

```bash
# Build (Debug artifacts land in build/DerivedData/Build/Products/Debug/NotchNotch.app)
xcodebuild -scheme NotchNotch -configuration Debug -derivedDataPath build/DerivedData build

# Release
xcodebuild -scheme NotchNotch -configuration Release -derivedDataPath build/DerivedData build

# Run with stdout visible (the app prints a lot of state-transition tracing)
build/DerivedData/Build/Products/Debug/NotchNotch.app/Contents/MacOS/NotchNotch 2>&1 | tee .temp/app_stdout.log

# Structured logging — the preferred way to watch the overlay without a debugger
log stream --predicate 'subsystem == "co.jianyuelab.NotchNotch"'
```

Categories in `Support/Log.swift`: `lifecycle`, `geometry`, `window`, `hover`, `state`,
`private-api`, `media`, `location`.

Only one process may hold port 7823, so kill a previously launched copy (`pkill -f NotchNotch`)
before relaunching or the agent HTTP server silently fails to bind.

### Verification

**There is no test target.** The project verifies changes by (a) building, (b) launching the app and
reading its stdout/`log stream`, and (c) screenshotting the overlay. Standalone `swift` scripts under
`.temp/` (gitignored) are the pattern used for pure-logic checks — see `.temp/test_layout.swift`.

The shell this agent runs in is **not Accessibility-trusted**: synthetic input events (`cliclick`,
CGEvent posting) are silently dropped, so hover/expand behaviour cannot be driven from the terminal.
Force the panel open via the distributed notification instead, then screenshot:

```bash
# Expand the running app's panel from outside, then screenshot it
swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(
  Notification.Name("co.jianyuelab.NotchNotch.expand"), object: nil, deliverImmediately: true)'
screencapture -x .temp/expanded.png
```

`co.jianyuelab.NotchNotch.selectTab` works the same way, with the tab key as the notification
`object` — lowercase `"overview"`, `"weather"`, `"shelf"`, `"clipboard"` (note: *not* the
`NotchActiveTab` raw values), plus `"settings"` to open the Settings window. Both names are also
observed on the in-process `NotificationCenter`.

Agent alert banners take over the panel and will interrupt a capture; suppress them with
`defaults write co.jianyuelab.NotchNotch co.jianyuelab.NotchNotch.agentMonitoringEnabled -bool false`
and `defaults delete` the key afterwards to restore the default.

## Architecture

### Ownership chain

`NotchNotchApp` (the only SwiftUI `Scene` is a `MenuBarExtra`; the overlay is *not* a scene) →
`AppDelegate` → **`NotchWindowController`**, which is the single file that knows about the window,
the state machine and the hover monitor at once. It also injects `NowPlayingController` and
`ShelfController`. Everything else (`ScheduleController`, `ClipboardManager`, `WeatherController`,
`AgentHarnessController`, `SystemMediaHUDController`) is a `.shared` singleton that self-starts in
its private `init`, so merely touching `.shared` begins polling/monitoring.

### The Notch/ quartet

- `NotchGeometry` — where the notch physically is. Two paths: hardware (`safeAreaInsets.top` +
  `auxiliaryTopLeftArea`/`auxiliaryTopRightArea`, notch = the gap between them) and simulated
  (centred `NSStatusBar.system.thickness` strip on notchless displays).
- `NotchLayout` — pure, `Sendable`, side-effect-free. Turns a geometry + `hasLiveActivity` flag into
  every rect: window frame, collapsed/expanded body, enter/exit hover regions, alert bar.
- `NotchStateMachine` — four states (`collapsed`/`expanding`/`expanded`/`collapsing`), not a Bool,
  because re-entry during `collapsing` must cancel the close and the window must stay interactive
  until the close finishes. Springs have no completion callback on macOS 13, so transient states end
  on a `settle` timer.
- `NotchOverlayWindow` — an `NSPanel` (`.nonactivatingPanel` so clicking never steals focus) at
  `.statusBar + 1`. All window-server decisions live here and nowhere else.
- `NotchHoverMonitor` — global + local `NSEvent` monitors *plus* a 40 Hz `DispatchSourceTimer` poll,
  because a global monitor stops seeing moves once the cursor is over our own window.

### The invariant that explains most of the code

**The `NSWindow` is sized once for the expanded panel and never resized.** Resizing a borderless
window per-frame fights SwiftUI's animator and stutters, so only the SwiftUI shape animates inside a
fixed transparent canvas.

The cost: a large invisible window sits over the menu bar, and macOS does **not** pass clicks through
the transparent pixels of a non-opaque window. Overriding `hitTest(_:)` does not help — the event has
already been taken from the other app by then. So `ignoresMouseEvents` is the only lever, and it must
track the *cursor*, not the state: `NotchWindowController.updateInteractivity` calls
`NotchLayout.acceptsClick(at:in:isShowingAlert:)` on every pointer move and every state change. If the
top of the screen ever goes dead, this is the code to look at.

### The expanded panel's vertical budget

The 174pt panel is divided exactly: `7 (top pad) + 26 (top bar) + 7 (spacing) +
NotchConfiguration.expandedContentRowHeight (120) + 14 (bottom pad)`. Every tab card must fit that
120pt row.

GOTCHA: `.frame(height:)` does **not** clip in SwiftUI — a card that cannot compress renders at its
own minimum, *centred* on the slot, and bleeds out of both ends of the panel. Because all four tabs
share one ZStack, an oversized card used to resize that ZStack and break the layout of the other
tabs while being the hidden one. `NotchPanelView.tabSlot(_:content:)` now pins each tab to the row
height and clips it, so a regression is contained to its own tab — but the card still has to fit.

Everything in `Notch/` is in AppKit **screen coordinates** (bottom-left origin, +Y up) — the same
space as `NSScreen.frame`, `NSWindow.setFrame` and `NSEvent.mouseLocation`. No flipping until inside
the hosting view.

Other gotchas already encoded in comments, worth not re-learning: `@Published` emits in `willSet`, so
inside `stateMachine.$state.sink` the property still holds the *old* value — use the closure argument;
state mutations must happen *inside* `withAnimation` on the same synchronous turn as the triggering
event; and `orderFrontRegardless()` is required because an accessory app is never "active".

### Live activity → compact width

`NotchWindowController.observeLiveActivities()` is the single aggregation point. A `CombineLatest4` of
now-playing / schedule / agent / weather decides `hasLiveActivity`, which widens the collapsed body by
`compactWidthExtension` to reveal the ear indicators. Adding a new "ear" feature means extending both
that publisher **and** the identical inline recomputation in `reload()`.

### Media (`Media/` + `PrivateAPI/MediaRemoteBridge.swift`)

`NowPlayingSource` is the seam. `CompositeNowPlayingSource` runs every backend at once and picks a
winner by priority (actively playing → has any track), backfilling missing artwork/duration from the
losers, and routes transport commands to whichever backend currently owns the track. Backend order is
chosen in exactly one place — the `NowPlayingController(source:)` initializer in
`NotchWindowController`: MediaRemote → Spotify AppleScript → Music AppleScript → Accessibility.

### Private API

`PrivateAPI/MediaRemoteBridge.swift` and `PrivateAPI/PrivateWindowElevation.swift` are the **only**
files touching SPI. Both resolve symbols with `dlopen`/`dlsym` at runtime rather than linking, so a
removed symbol degrades to `isAvailable == false` instead of a dyld launch failure. Nothing there
traps or force-unwraps. Window elevation is additionally gated behind
`NotchConfiguration.usesPrivateWindowElevation` (currently `false`). Keep new SPI use inside these
files.

### Agent harness (`Agent/`)

Two ingestion paths into `AgentHarnessController`:
1. `AgentHTTPServer` — a dependency-free `NWListener` on `127.0.0.1:7823`, POST JSON to `/event`.
   Recognised keys: `state`, `agent`, `event`, `session_id`, `cwd`, `title`, `terminal`, `pid`.
   `state` matching is deliberately fuzzy (`waitinguser`/`waiting_user`/`reply`/`action` all map to
   `.waitingUser`) so different CLI hook scripts can post without a shared schema.
2. Process polling — `ps` snapshot parsing that recognises Claude Code, Antigravity, Codex, OpenCode
   and Aider, then climbs the kernel PPID tree (`proc_pidinfo`/`proc_bsdinfo`, with a tmux special
   case) to find the hosting GUI terminal so the alert can focus it.

Both are toggleable; when monitoring is off nothing is started at all.

### Configuration and tokens

`App/NotchConfiguration.swift` holds every tunable number (sizes, radii, hover margins, all timings
and animation curves, poll intervals). Change values there, not at the use site.

`Support/JYLTheme.swift` mirrors the `@jianyuelab/tokens` design system. Use `JYLTheme.*` colors and
the `.jylCard()` modifier rather than literal colors.

### Localization

Bilingual (Simplified Chinese / English) via `Localization/L10n.swift` — a type-safe `L10nKey` enum
with two dictionaries that must stay at **100% key parity** — and `LocalizationManager.shared`
(`.system`/`.zhHans`/`.en`, persisted, hot-reloads without restart). Views `@ObservedObject` the
manager and call `L10n.tr(.key)`. Some short strings use an inline `loc.isChinese ? "中文" : "English"`
ternary; both idioms are in use. Any new user-facing string needs a key added to both tables.

## Conventions

- Swift 6 strict concurrency. UI/controllers are `@MainActor`; pure value types and namespaces are
  marked `nonisolated` (`NotchLayout`, `NotchGeometry`, `NotchConfiguration`, `Log`, model enums).
- Comments in this codebase explain *why* — especially the AppKit/window-server reasoning. Preserve
  them when editing; they are the accumulated debugging history.
- Scratch files, test scripts and screenshots go in `.temp/` (gitignored), never `/tmp`.
- Design specs and implementation plans live in `docs/superpowers/specs/` and
  `docs/superpowers/plans/`, named `YYYY-MM-DD-topic[-design].md`.
- Commits use Conventional Commits with a scope: `fix(layout):`, `feat(weather):`, `docs:`, `chore:`.
- Version lives in `MARKETING_VERSION` in `NotchNotch.xcodeproj/project.pbxproj` — **two** places
  (Debug and Release); bump both.
- Entitlements (`NotchNotch.entitlements`): Apple Events, Calendars, network client **and server**
  (the agent listener). Hardened runtime is on; new capabilities need an entitlement plus an
  `INFOPLIST_KEY_NS*UsageDescription` in the pbxproj.
