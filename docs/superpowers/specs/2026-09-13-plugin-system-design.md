# Plugin System Specification

## Overview

This specification details a plugin system for NotchNotch that lets third parties extend the notch
overlay with **Vue 3 single-file components**, rendered as **native SwiftUI** rather than as web
content.

Plugin JavaScript runs in an in-process `JSContext` (JavaScriptCore). Plugins author real `.vue`
SFCs against a custom Vue renderer whose elements are SwiftUI primitives (`nn-vstack`, `nn-text`,
`nn-icon`, …) instead of DOM nodes. The resulting node tree crosses the bridge as JSON and is
rendered by a recursive SwiftUI view. There is no `WKWebView`, no DOM, no browser process, and no
loadable binary code.

The same work introduces a **module registry** that unifies the four hardcoded built-in tabs and the
plugin surfaces behind one protocol, eliminating the duplicated live-activity aggregation that
`CLAUDE.md` currently flags as a maintenance trap.

---

## Goals & Non-Goals

### Goals

- **Vue authoring, native rendering.** Plugin authors write Vue 3 SFCs with full reactivity,
  components and lifecycle. Output is genuine SwiftUI, so plugins are visually indistinguishable
  from built-in cards by construction.
- **Four surfaces.** A plugin may contribute an expanded tab card, a collapsed-pill ear (live
  activity), a transient alert banner, and a settings pane.
- **Near-zero idle cost.** A background plugin holds **no resident JS context between wakes**. App
  launch evaluates no plugin code at all.
- **Capability security.** Deny-by-default, manifest-declared, Swift-enforced capabilities covering
  network, subprocess execution, storage and system affordances.
- **Failure isolation.** A misbehaving plugin degrades to an inline error card. It cannot crash the
  app, block the UI thread, exceed its granted capabilities, or survive the watchdog.
- **Inspectable distribution.** Plugins are plain readable folders on disk, installable by drag-and-drop
  onto the notch or via a Settings file picker.
- **Bilingual parity.** Manifest strings are `{en, zh-Hans}` maps, consistent with the app's existing
  100%-key-parity localization rule.
- **Registry unification.** Built-in features become registered modules. Their view code is not
  rewritten.

### Non-Goals

- **No WKWebView, no HTML/CSS.** Plugins get the `nn-*` element vocabulary, not arbitrary web
  rendering. (Evaluated and rejected: ~60–120 MB per web process contradicts the cost goal.)
- **No loadable binary plugins.** No `.dylib`/`.bundle` loading, so no
  `com.apple.security.cs.disable-library-validation` and no ABI compatibility burden.
- **No plugin code signing or a plugin registry/marketplace in this phase.** Trust is
  inspection-based; see *Provenance*.
- **No rewriting built-in cards as Vue plugins.** Built-in views stay native Swift.
- **No App Store distribution.** The `exec` capability rules this out permanently. Direct/notarized
  distribution only.
- **No shell interpretation.** `host.exec` never invokes `sh -c`.

---

## Architecture & Subsystems

```
NotchNotch/
├── Modules/                        # NEW — the unified registry (Approach B)
│   ├── NotchModule.swift           # the surface protocol
│   ├── ModuleRegistry.swift        # ordering, enablement, live-activity aggregation, alert queue
│   ├── EarState.swift              # declarative ear template
│   ├── AlertRequest.swift          # declarative alert template
│   └── BuiltIn/
│       ├── OverviewModule.swift    # thin adapters (~40 lines each) around existing
│       ├── WeatherModule.swift     # controllers + views. No view code is rewritten.
│       ├── ShelfModule.swift
│       ├── ClipboardModule.swift
│       ├── AgentModule.swift       # ear + alert only (no tab card)
│       └── ScheduleModule.swift    # ear + alert only (no tab card)
├── Plugins/                        # NEW — the JS plugin subsystem
│   ├── PluginManifest.swift        # manifest decoding + validation + runtime-version gate
│   ├── PluginStore.swift           # discovery, install, enable/disable, permission grants
│   ├── PluginRuntime.swift         # JSVirtualMachine / JSContext lifecycle, serial queue, watchdog
│   ├── PluginBridge.swift          # host API injection + capability enforcement
│   ├── PluginNode.swift            # Sendable value tree decoded from the renderer snapshot
│   ├── PluginNodeView.swift        # recursive SwiftUI renderer for the node tree
│   ├── PluginVocabulary.swift      # element + prop table (source of truth)
│   └── JSPluginModule.swift        # NotchModule conformance backed by a plugin
├── Resources/
│   └── nn-runtime.js               # NEW — prebuilt Vue runtime-core + custom renderer (committed)
└── Support/Log.swift               # MODIFIED — add the `plugin` category

sdk/                                # NEW — bun workspace, versioned with the app
├── runtime/                        # builds NotchNotch/Resources/nn-runtime.js
└── plugin/                         # @notchnotch/plugin: definePlugin, TS types, Vite preset

examples/
└── hello-notch/                    # NEW — working reference plugin
```

**Modified existing files:** `Views/NotchPanelView.swift`, `Notch/NotchWindowController.swift`,
`Views/SettingsView.swift`, `Support/Log.swift`, `Localization/L10n.swift` (new keys),
`NotchNotch.entitlements` + pbxproj (JIT entitlement).

**Explicitly untouched:** `NowPlayingView`, `WeatherCardView`, `DropShelfView`,
`ClipboardCardView`, `ScheduleTimelineCardView`, and every controller in `Media/`, `Weather/`,
`Schedule/`, `Clipboard/`, `Shelf/`, `Agent/`.

---

## 1. JS Runtime & the Vue↔SwiftUI Bridge

### 1.1 Threading and concurrency

One shared `JSVirtualMachine`; one `JSContext` per active plugin. All JS executes on a single serial
`DispatchQueue`, following the existing `AgentHTTPServer` shape:

```swift
nonisolated final class PluginRuntime: @unchecked Sendable {
    private let queue = DispatchQueue(label: "co.jianyuelab.NotchNotch.pluginJS", qos: .utility)
    private let vm = JSVirtualMachine()
    private var contexts: [String: JSContext] = [:]   // queue-confined
}
```

`JSContext` and `JSValue` are not `Sendable` and never leave the queue. Only decoded value types
(`PluginNode`, `EarState`, `AlertRequest`) cross to `@MainActor`.

**Known tradeoff:** contexts within one `JSVirtualMachine` serialize, so one plugin's slow turn
delays other plugins. This is accepted for the expected 1–5 mostly-idle plugins, in exchange for not
paying a separate heap per plugin. Mitigations: the watchdog (§5.4), staggered wakes (§5.2), and
`host.exec` for genuinely long work. Escape hatch if it ever bites: a manifest opt-in to an isolated
VM. Not implemented in this phase.

### 1.2 The host runtime bundle

`Resources/nn-runtime.js` is a prebuilt bundle containing `@vue/runtime-core` and the NotchNotch
custom renderer, evaluated into each context immediately before the plugin bundle. Plugin bundles
mark `vue` and `@notchnotch/plugin` as externals.

Rationale: the Vue runtime is parsed once per context rather than once per plugin; the host owns the
renderer version rather than each plugin pinning its own; and the Xcode build never requires node,
because the file is built by `bun` under `sdk/runtime/` and **committed**.

### 1.3 Rendering

Plugin `.vue` SFCs are compiled at the *plugin author's* build time by `@vitejs/plugin-vue`, with
`compilerOptions.isCustomElement` matching `/^nn-/`.

At runtime the custom renderer (`createRenderer` from `@vue/runtime-core`) implements
`createElement`, `insert`, `remove`, `patchProp`, `setElementText` and friends against a plain-object
tree in JS. Each node is assigned a monotonically increasing integer id at creation.

On Vue's post-flush tick, the runtime serializes the **whole tree** to JSON and calls into Swift.

**Full snapshots rather than a patch protocol, deliberately.** A 120pt card is 10–50 nodes, so a
snapshot is a few KB. This removes an entire class of mirror-tree desync bugs at negligible cost.
Node ids are used as SwiftUI `.id()` so view identity, `@State` and implicit animation remain stable
across snapshots.

Snapshot serialization is **suppressed entirely** when the panel is collapsed or the plugin's tab is
not the active one, and otherwise coalesced to a maximum of 20 Hz. Plugins are expected to animate
via native modifiers (e.g. `nn-progress` receiving a new value, which SwiftUI interpolates) rather
than by driving frames across the bridge.

### 1.4 Element vocabulary (runtime version 1)

| Element | Maps to |
|---|---|
| `nn-vstack` / `nn-hstack` / `nn-zstack` | `VStack` / `HStack` / `ZStack` |
| `nn-spacer` | `Spacer` |
| `nn-scroll` | `ScrollView` (`axis="h" \| "v"`) |
| `nn-text` | `Text` |
| `nn-icon` | `Image(systemName:)` — SF Symbol |
| `nn-image` | `Image` from https/data URL, cached, size-capped |
| `nn-rect` | `RoundedRectangle` (fill / stroke / corner) |
| `nn-progress` | linear bar or ring (`style="bar" \| "ring"`) |
| `nn-button` | `Button` wrapping its children, `TabButtonStyle` |
| `nn-card` | container with the existing `.jylCard()` modifier |

Props are a fixed table mapped to SwiftUI modifiers: `font-size`, `font-weight`, `font-design`,
`color`, `background`, `padding`, `width`/`height`/`max-width`/`max-height`, `spacing`, `align`,
`corner-radius`, `opacity`, `line-limit`, `border`.

`color` and `background` accept **JYLTheme token names** (`primary`, `textSecondary`, `chart3`,
`success`, …) in preference to hex literals, so plugins inherit the design system. Hex is accepted
as a fallback.

Unknown elements render as an empty container; unknown props are ignored. Both emit a
`Log.plugin` warning — this is the drift guard between the Swift table and the hand-written TS types
(§4.4).

### 1.5 Events

A prop whose value is a function serializes as a boolean marker (`{"onClick": true}`). A tap
dispatches `(pluginId, nodeId, "click")` onto the JS queue; Vue's handler runs; the resulting state
change produces the next snapshot.

### 1.6 Risks to verify during implementation

1. **JIT under hardened runtime.** JavaScriptCore's JIT requires
   `com.apple.security.cs.allow-jit`. Expected behaviour without it is a fall back to the LLInt
   interpreter (functional, slower). The entitlement is added regardless, but the no-entitlement
   fallback must be **empirically confirmed rather than assumed**, because the failure mode if
   wrong is a launch-time crash.
2. **`@vue/compiler-dom` output.** Vue's template compiler emits DOM-flavoured `class`/`style`
   normalization helpers. NativeScript-Vue ships on this same footing, so it is proven, but
   `patchProp` must tolerate normalized `class` and `style` props arriving for elements that have no
   CSS concept.

---

## 2. Module Registry

### 2.1 Protocol

```swift
@MainActor
protocol NotchModule: AnyObject {
    var id: String { get }              // "builtin.weather" | "plugin.<manifest-id>"
    var title: String { get }           // already localized
    var iconName: String { get }        // SF Symbol for the tab button
    var badge: String? { get }          // e.g. the shelf's item count
    var providesCard: Bool { get }
    func cardView() -> AnyView
    var earState: EarState? { get }     // nil == not contributing live activity
}
```

`AnyView` rather than an associated type, so modules are usable as existentials. One erasure per
visible tab per render is immaterial.

### 2.2 Reactivity boundary

`ModuleRegistry` is an `ObservableObject` that publishes **structural change only**: which modules
exist, their order, enablement, badges, ear state, and the active alert.

Card views continue to observe their own controllers directly, exactly as `WeatherCardView` observes
`WeatherController.shared` today. Funnelling leaf reactivity through the registry would invalidate
the entire panel on every now-playing tick.

### 2.3 Ear template

```swift
struct EarState: Equatable {
    enum Leading  { case icon(symbol: String, tint: Token, fill: Token)
                    case artwork(NSImage)
                    case none }
    enum Trailing { case ring(progress: Double, tint: Token)
                    case spinner(tint: Token)
                    case text(String, tint: Token)
                    case badge(String, tint: Token)
                    case none }
    var leading: Leading
    var trailing: Trailing
    var priority: Int
    var expiresAt: Date?     // lets a dormant plugin's stale ear self-retire
}
```

`Token` is a `JYLTheme` colour-token identifier (`primary`, `textSecondary`, `success`, `chart3`, …)
rather than a raw `Color`, so ear content is expressed in design-system terms and cannot introduce
off-palette colours. It is the same token type accepted by the `color` / `background` props in §1.4.

This covers every ear that exists today: music = `artwork` + `ring`; agent working = `icon` +
`spinner`; agent waiting-user = `icon` + `badge("REPLY")`; agent waiting-subagent = `icon` +
`badge("SUB")`; schedule = `icon` + `ring`; weather = `icon` + `text`.

Consequently the ~130 lines of `if/else` in `compactLeftEar` / `compactRightEar` collapse to
"select the highest-priority non-`nil` `earState`, render its two halves" — roughly 30 lines.

`OverviewModule` is pinned to the first position and cannot be disabled or reordered — it is the
state the panel resets to on collapse, so it must always exist. Every other module, built-in or
plugin, is freely reorderable and disableable.

Built-in priorities are seeded to reproduce today's exact precedence:
**music > agent > schedule > weather**. Plugins default below all built-ins and are reorderable in
Settings.

### 2.4 Live-activity aggregation (the duplication fix)

`hasLiveActivity` becomes a single `@Published` property on the registry:

```swift
hasLiveActivity = modules.contains { $0.isEnabled && $0.earState != nil }
```

`NotchWindowController.observeLiveActivities()` subscribes to that one publisher in place of the
`CombineLatest4`, and `reload()` reads the same property instead of recomputing the condition
inline. The two-site duplication documented in `CLAUDE.md` is removed rather than extended to three
sites.

### 2.5 Alert queue

```swift
struct AlertRequest {
    let moduleId: String
    let icon: String, tint: Token
    let title: String, badge: String?
    let action: AlertAction?      // .focusSession | .openTab | .openURL | .pluginEvent
    let duration: TimeInterval
    let priority: Int
}
```

The registry owns the queue and exposes `activeAlert`. The agent and schedule banners migrate onto
it; plugins post into it. The volume/brightness HUD remains a separate branch — it is not
user-extensible and its bar layout differs — so `NotchPanelView` goes from three alert branches to
two.

### 2.6 Tab bar and layout invariants

`NotchActiveTab` is replaced by `activeModuleID: String`. The tab button row becomes a `ForEach`
over enabled card-providing modules in registry order; the content row becomes a `ForEach` of
`tabSlot(moduleID) { module.cardView() }`.

**The `tabSlot` invariant carries over verbatim**: every slot is pinned to
`NotchConfiguration.expandedContentRowHeight` and `.clipped()`, so an oversized plugin card is
contained to its own tab and cannot resize the shared `ZStack`. Plugin node trees are additionally
clamped to the row height by the renderer.

### 2.7 Backwards compatibility (non-negotiable)

The `co.jianyuelab.NotchNotch.selectTab` distributed notification must keep accepting the exact
strings `"overview"`, `"weather"`, `"shelf"`, `"clipboard"` and `"settings"`, mapped to built-in
module ids, and additionally accept plugin module ids. This notification is the documented headless
verification path for the whole project and cannot regress.

---

## 3. Capabilities & Permissions

All enforcement is in Swift, inside `PluginBridge`. No JS-side check is trusted.

### 3.1 Declaration

```json
"capabilities": {
  "net":     { "hosts": ["api.github.com", "*.internal.dev"] },
  "exec":    { "binaries": ["/usr/bin/git", "gh"] },
  "storage": {},
  "system":  { "openURL": true, "notify": true,
               "clipboard": "read", "appData": ["nowPlaying"] }
}
```

### 3.2 Two denial modes

- **Undeclared** — the host API is not injected at all, so `typeof host.exec === "undefined"` and
  the plugin can feature-detect.
- **Declared but not granted** — present, but throws a typed `PermissionError`, so the plugin can
  render its own "grant me network access" state rather than silently failing.

### 3.3 Granting

Nothing executes at install time. Settings presents a permission sheet spelling out the actual
allowlists in plain language; the plugin remains inert until explicitly enabled.

The capability block is hashed. If an update changes it, permissions are reduced to the new set and
anything newly requested is re-prompted rather than inherited.

The sheet must call out dangerous **combinations** explicitly — `net` together with
`clipboard: "read"`, or `net` together with `exec`, constitutes exfiltration capability, and listing
those neutrally on separate lines would be misleading.

### 3.4 `net`

Enforced inside the native `fetch` implementation. Exact host match, `*.`-prefix wildcards only
(no other patterns). HTTPS only, except `localhost` / `127.0.0.1`, which remain plain-HTTP-capable
because local dev-server status is an obvious first plugin. Response body capped at 5 MB.

### 3.5 `exec`

A **second, separate toggle** that remains off even after the plugin is otherwise enabled.

- `Process` with an explicit `executableURL` and an arguments array. **Never `sh -c`** — pipelines
  are composed in JS, so plugin-built strings have no shell injection surface.
- Bare binary names are resolved once at grant time through a fixed `PATH`
  (`/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin`) and thereafter pinned to the
  resolved absolute path.
- Sanitized environment: `HOME`, the fixed `PATH`, `LANG`. The user's real environment is not
  passed, as it routinely contains secrets.
- 10 s default timeout (manifest may request up to 60 s); 1 MB output cap.
- Returns `{ code, stdout, stderr }` to JS as a Promise.

**Stated limitation:** the binary allowlist is defence-in-depth, not a security boundary. Granting
`git` permits arbitrary code execution the moment the plugin touches a repository with hostile hooks
or `core.fsmonitor`. Granting `exec` is functionally full user-level trust, and the permission sheet
must say so rather than implying containment.

### 3.6 `system`

Prompted per sub-capability. Clipboard *read* is prompted separately from *write*. `appData` names
specific read-only projections (`nowPlaying`, `calendar`, `weather`); calendar contents are the most
sensitive data the app holds and are never exposed implicitly.

### 3.7 `storage`

No prompt required: a per-plugin JSON file under Application Support, 1 MB cap, scoped to the
plugin. Timers are not a capability — they are a runtime primitive, budgeted rather than
permissioned (§5).

### 3.8 Provenance

No plugin code signing in this phase. Instead: plugins are plain readable JavaScript in a visible
folder, with "Reveal in Finder" and a manifest viewer in Settings, plus a global
**disable all plugins** kill switch. Trust is inspection-based and social.

---

## 4. Package Format & SDK

### 4.1 On-disk layout

```
~/Library/Application Support/NotchNotch/Plugins/<id>/
├── manifest.json
├── plugin.js        # single bundle; `vue` and `@notchnotch/plugin` are externals
├── icon.png         # optional; falls back to the manifest SF Symbol
└── README.md        # optional; shown in Settings
```

### 4.2 Installation

Two paths, both landing in the directory above:

1. A file picker in Settings.
2. **Dragging a `.notchplugin` folder or a zip onto the notch.** `NotchPanelView` already accepts
   file drops for the Drop Shelf; the existing handler checks for a `manifest.json` and routes to
   the installer instead of the shelf.

### 4.3 Manifest

```json
{
  "id": "co.example.ci-status",
  "name":        { "en": "CI Status", "zh-Hans": "构建状态" },
  "description": { "en": "GitHub Actions at a glance", "zh-Hans": "一眼查看 GitHub Actions" },
  "version": "1.0.0",
  "author": "example",
  "homepage": "https://example.com",
  "runtime": 1,
  "entry": "plugin.js",
  "icon": "chart.bar.fill",
  "surfaces": ["card", "ear", "alert"],
  "capabilities": { "net": { "hosts": ["api.github.com"] }, "storage": {} },
  "background": { "wakeInterval": 300 },
  "settings": [
    { "key": "repo",     "type": "text",   "label": { "en": "Repository", "zh-Hans": "仓库" }, "default": "" },
    { "key": "showEar",  "type": "toggle", "label": { "en": "Show in ears", "zh-Hans": "在耳朵中显示" }, "default": true },
    { "key": "interval", "type": "select", "label": { "en": "Refresh", "zh-Hans": "刷新间隔" },
      "options": [ { "value": "300", "label": { "en": "5 min", "zh-Hans": "5 分钟" } } ], "default": "300" }
  ]
}
```

Settings field types: `text`, `toggle`, `select`, `number`. Rendered natively by the host into the
Settings window.

Every user-facing string is a `{en, zh-Hans}` map, or a bare string meaning "identical in both".
This keeps plugins consistent with the app's localization parity rule without forcing bilingual
authorship.

**`"runtime": 1`** is the element-vocabulary compatibility gate. The host refuses to load a plugin
declaring a runtime version it does not implement, showing a legible message rather than a broken
card. This is the mechanism by which the `nn-*` vocabulary can grow without breaking installed
plugins.

### 4.4 SDK

A `bun` workspace under `sdk/`, versioned alongside the app:

- **`sdk/runtime/`** — builds `NotchNotch/Resources/nn-runtime.js` (Vue runtime-core + custom
  renderer + host shims). Output is committed.
- **`sdk/plugin/`** — the `@notchnotch/plugin` package: `definePlugin()`, TypeScript types for the
  host API, component typings for the `nn-*` elements (so Volar type-checks plugin templates), and a
  Vite preset that sets `isCustomElement`, externalizes `vue`, and emits a single IIFE.
- **`examples/hello-notch/`** — a working reference plugin to copy.

```ts
import { definePlugin } from '@notchnotch/plugin'
import Card from './Card.vue'

export default definePlugin({
  card: Card,
  setup(host) {
    host.watch(async () => {
      const r = await host.fetch('https://api.github.com/…')
      state.value = await r.json()
      host.setEar({ leading:  { icon: 'checkmark.seal.fill', tint: 'success' },
                    trailing: { badge: 'OK' } })
    }, { interval: 300 })
  }
})
```

Ears and alerts are **imperative host calls** (`host.setEar`, `host.clearEar`, `host.postAlert`),
not components — consistent with the "full node tree in cards, fixed templates in ears and alerts"
split. Ear state is **persisted by the host**, which is what allows a dormant plugin to keep showing
an ear after its JS context has been torn down.

`host.settings` is a reactive object; editing a value in the Settings window pushes into it and
triggers a re-render.

### 4.5 Developer experience

`bun run dev` writes the built bundle into the live plugins directory. With **developer mode**
enabled in Settings, the host watches the plugin directory (`DispatchSource`), tears down the
context and re-evaluates on change — hot reload while the panel is open. Storage and settings values
survive the reload.

### 4.6 Accepted imperfection

The element and prop vocabulary is defined in Swift (`PluginVocabulary.swift`) and the TypeScript
types are hand-written against it, rather than generated from a shared schema. Codegen for a
~12-element table is over-engineering. The drift guard is the logged warning emitted whenever the
renderer receives an unknown element or prop (§1.4), which surfaces mismatches immediately during
development.

---

## 5. Lifecycle & Cost Controls

### 5.1 States

| State | Condition | Cost |
|---|---|---|
| Disabled | not enabled by the user | manifest only |
| Dormant | enabled, no background surface, panel collapsed | zero — no context exists |
| Background | declares an ear or alert surface | nothing resident between wakes |
| Foreground | its tab is the visible one in an expanded panel | context + snapshot flushes ≤ 20 Hz |

**Background plugins are wake-driven, not resident.** When `wakeInterval >= 60s`, the host owns the
timer: it wakes the plugin, evaluates `nn-runtime.js` + `plugin.js`, runs the plugin's refresh,
captures the ear snapshot, and tears the context down again. Because ear state is host-persisted
(§4.4), the ear continues to display with no JS alive behind it.

A plugin polling every 5 minutes therefore costs a few milliseconds of CPU every 5 minutes and zero
resident memory. This is what makes "all four surfaces" compatible with "minimum cost".

Intervals below 60 s stay resident and are clamped against a host-enforced floor regardless of what
the manifest requests.

Transitions: expanding the panel promotes the active tab's plugin to foreground, creating its
context if needed. Collapsing demotes after a 5 s grace period, so rapid open/close does not thrash
context creation.

### 5.2 Launch and scheduling protection

This is an `LSUIElement` login-item agent, so **no plugin JS is evaluated at startup**. The registry
is built from manifests only (a few KB of JSON each). First background wakes are *scheduled with
jitter*, never fired during launch.

Wakes are staggered so multiple plugins do not converge on the same second, suspended on display
sleep via `NSWorkspace` notifications, and backed off under Low Power Mode.

### 5.3 Render gating

Snapshot serialization is skipped entirely when the panel is collapsed, and when the plugin's tab is
not the active one. An expanded panel showing Weather costs a CI plugin nothing, while its
background wake continues to keep its ear current.

### 5.4 Watchdog

Any JS turn exceeding 250 ms is logged. Three strikes auto-disable the plugin and surface a banner
in Settings. JS runs off the main thread, so a hang cannot freeze the panel; the watchdog exists
because a hung turn delays *other* plugins on the shared VM (§1.1).

### 5.5 Input limits

There is no public API to hard-cap a `JSContext`'s heap, so limits are applied to inputs instead,
each clamped-and-logged rather than fatal:

| Limit | Value |
|---|---|
| Nodes per render tree | 400 |
| Storage file | 1 MB |
| `fetch` response body | 5 MB |
| `nn-image` decoded source | 2 MB |
| `exec` output | 1 MB |
| `exec` timeout | 10 s default / 60 s max |

### 5.6 Failure isolation

A plugin that throws during evaluation or render produces an inline error card
("plugin failed — see Settings") with the stack captured for the Settings pane. Never a crash, never
a blank panel. A plugin cannot exceed its granted capabilities, cannot block the UI thread, and can
be terminated by the watchdog or the global kill switch.

---

## 6. Observability & Verification

The project has **no test target**; verification follows the existing build → launch → read logs →
screenshot workflow.

**Logging.** A new `plugin` category in `Support/Log.swift`, alongside `lifecycle`, `geometry`,
`window`, `hover`, `state`, `private-api` and `media`. It emits: wake, eval duration (ms), JS turn
duration (ms), snapshot node count, teardown, permission denial, and vocabulary drift warnings. The
whole cost picture is then visible through:

```bash
log stream --predicate 'subsystem == "co.jianyuelab.NotchNotch"'
```

**Settings.** A compact per-plugin activity row (last wake, average turn duration) — the only way a
user can determine *which* plugin is costing them.

**Pure-logic verification** uses standalone `.temp/` Swift scripts, per the established
`.temp/test_layout.swift` pattern, covering: node-tree decoding, ear priority selection, permission
host/binary matching, and manifest validation including the runtime-version gate.

**Visual verification** uses `examples/hello-notch` installed into the plugins directory, driven by
the `selectTab` distributed notification and captured with `screencapture`, with agent alert banners
suppressed via the documented `defaults write` for `agentMonitoringEnabled`.

**Cost figures in this document are engineering estimates, not commitments.** Measuring actual wake
cost, eval duration, resident memory per foreground context and steady-state idle CPU is an explicit
implementation task, not an assumption.

---

## 6a. Configuration Constants

Per the project convention that every tunable number lives in `App/NotchConfiguration.swift` rather
than at its use site, the following are added there, not inlined:

`pluginFlushMaxRate` (20 Hz), `pluginForegroundGracePeriod` (5 s), `pluginWatchdogTurnLimit`
(250 ms), `pluginWatchdogStrikes` (3), `pluginMinWakeInterval` (60 s), `pluginResidentThreshold`
(60 s), `pluginWakeJitterFraction`, `pluginMaxNodes` (400), `pluginMaxStorageBytes`,
`pluginMaxFetchBytes`, `pluginMaxImageBytes`, `pluginMaxExecOutputBytes`,
`pluginExecTimeoutDefault` / `pluginExecTimeoutMax`.

---

## 7. Build & Packaging Changes

- **Entitlements** (`NotchNotch.entitlements`): add `com.apple.security.cs.allow-jit` for
  JavaScriptCore. Network client is already present. No new usage-description strings are required
  by the runtime itself; `system.notify` requires the standard user-notification authorization flow
  at first use.
- **Version**: bump `MARKETING_VERSION` in **both** Debug and Release configurations in
  `NotchNotch.xcodeproj/project.pbxproj`.
- **`nn-runtime.js`** is added to the app target's Copy Bundle Resources phase. It is a committed
  build product; the Xcode build does not invoke `bun` or node.
- **`.gitignore`**: add `sdk/**/node_modules`, `sdk/**/dist`, `examples/**/node_modules`,
  `examples/**/dist`. `NotchNotch/Resources/nn-runtime.js` is deliberately **not** ignored.
- **Distribution**: direct/notarized only. The `exec` capability is incompatible with the Mac App
  Store.

---

## 8. Implementation Phases

Ordered so that each phase is independently buildable and verifiable.

1. **Module registry.** `NotchModule`, `ModuleRegistry`, `EarState`, `AlertRequest`, six built-in
   adapters. Refactor `NotchPanelView` (tab row, ear rendering, alert queue) and
   `NotchWindowController` (single live-activity publisher, `reload()` deduplication). *Verify: the
   app is visually and behaviourally identical to today; `selectTab` still works for all five
   strings.* This phase ships value on its own by removing the documented duplication.
2. **SDK skeleton + runtime bundle.** `sdk/runtime`, `sdk/plugin`, the committed `nn-runtime.js`,
   and `examples/hello-notch` rendering a static tree.
3. **Runtime and bridge.** `PluginRuntime`, `PluginNode`, `PluginNodeView`, `PluginVocabulary`,
   `JSPluginModule`. First goal: the example plugin's card renders as SwiftUI. Confirm the JIT
   entitlement question (§1.6) here, before anything depends on it.
4. **Manifest, store, permissions.** `PluginManifest`, `PluginStore`, `PluginBridge` with `storage`
   and `net` first, then `system`, then `exec` behind its separate toggle. Settings UI for the
   module list, permission sheet and plugin settings schema.
5. **Ears, alerts, lifecycle.** Ear persistence, alert posting, wake scheduling, teardown, render
   gating, watchdog, input limits, activity row.
6. **Developer experience.** Hot reload, developer mode toggle, drag-to-install, README/manifest
   viewer.

---

## 9. Open Questions Resolved in This Design

| Question | Resolution |
|---|---|
| Web view or native rendering? | Native. Vue custom renderer → SwiftUI. No WKWebView. |
| Which surfaces? | All four: card, ear, alert, settings. |
| Full node trees everywhere? | No. Full trees in cards only; ears and alerts are fixed templates. |
| Patch protocol or snapshots? | Full snapshots, coalesced and gated. |
| Do built-ins migrate? | Yes to the registry; no rewrite of their views. |
| Per-plugin JS VM? | No — shared VM, watchdog-guarded. Isolated VM is a future opt-in. |
| Plugin signing? | Not in this phase. Inspection-based trust plus a kill switch. |
| App Store? | Ruled out by `exec`. Direct/notarized distribution. |
