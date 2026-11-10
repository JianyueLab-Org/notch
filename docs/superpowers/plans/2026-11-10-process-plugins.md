# Process Plugins Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move agent detection and omp support out of the NotchNotch core into process plugins, leaving the core with the notch UI, a session hub, focus, an HTTP listener and a plugin host.

**Architecture:** The core scans `~/Library/Application Support/NotchNotch/Plugins/<id>/manifest.json`, launches `managed` plugins and reads JSON lines from their stdout, and accepts the same messages over `127.0.0.1:7823`. `ActivityHub` replaces `AgentHarnessController` and is agent-agnostic. The agent plugin is a SwiftPM command-line tool in `plugins/agents/`; the omp plugin is the omp extension plus an `external` manifest in `plugins/omp/`.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI + AppKit, Network.framework, SwiftPM, TypeScript (omp extension), Nix (home-manager).

**Spec:** `docs/superpowers/specs/2026-11-10-process-plugins-design.md`

## Global Constraints

- macOS 13.0+, arm64, Swift 6 language mode, no package dependencies in the app or the agent plugin.
- UI/controllers are `@MainActor`; pure value types and namespaces are `nonisolated`.
- Pure logic files import Foundation (and Darwin where noted) only, so `.temp/` scripts can compile them with `swiftc`.
- Every new user-facing string gets a key in both `L10n` tables (100% parity).
- Comments explain *why*. Keep existing why-comments when moving code.
- Scratch scripts go in `.temp/` (gitignored), never `/tmp`.
- Conventional Commits with a scope.
- App, agent plugin and omp plugin version: `27.2.0`. `MARKETING_VERSION` lives in two places in `project.pbxproj`.
- Plugin API version: `1`.
- Plugin ids: agent plugin `co.jianyuelab.notchnotch.agents`, omp plugin `co.jianyuelab.notchnotch.omp`. Built-in HTTP source id `http`.
- UserDefaults keys: `co.jianyuelab.NotchNotch.httpListenerEnabled`, `co.jianyuelab.NotchNotch.plugin.<id>.enabled` (absent = enabled).
- Restart delays `1, 2, 4, 8` s; 5 exits within 600 s = crashed; stop grace 2 s; stderr tail 20 lines.
- Pid dedup hold: 180 s.
- The project has no XCTest target. Tests are `swift` scripts under `.temp/plugin-checks/`, compiled with the pure source files. Build: `xcodebuild -scheme NotchNotch -configuration Debug -derivedDataPath build/DerivedData build`.

## File Structure

| File | Responsibility |
|---|---|
| `NotchNotch/Activity/ActivityState.swift` | pure: `ActivityState` enum |
| `NotchNotch/Activity/ActivityState+Presentation.swift` | SwiftUI names, tags, icons, colours for `ActivityState` |
| `NotchNotch/Activity/ActivityRules.swift` | pure: `ActivitySource`, `ActivitySession`, pid dedup, priority, alert rule |
| `NotchNotch/Activity/ActivityHub.swift` | `@MainActor` session store, alerts, pruning, focus entry point |
| `NotchNotch/Activity/ActivityFocus.swift` | pid → GUI app activation (moved `DarwinProcessHelper`) |
| `NotchNotch/Plugins/PluginMessage.swift` | pure: message types, decoder, legacy mapping, `JSONLineBuffer` |
| `NotchNotch/Plugins/PluginManifest.swift` | pure: manifest decoding and validation |
| `NotchNotch/Plugins/PluginPreferences.swift` | pure: defaults keys and first-launch migration |
| `NotchNotch/Plugins/RestartPolicy.swift` | pure: backoff and crash decision |
| `NotchNotch/Plugins/ManagedPluginProcess.swift` | one child process: pipes, line reading, stop |
| `NotchNotch/Plugins/PluginHost.swift` | `@MainActor` discovery, enablement, launch/restart, HTTP routing |
| `NotchNotch/Plugins/PluginHTTPServer.swift` | renamed `AgentHTTPServer` |
| `NotchNotch/Views/PluginsSettingsSection.swift` | Settings → Plugins page |
| `plugins/agents/` | SwiftPM agent plugin, manifest, build script |
| `plugins/omp/` | omp extension + external manifest |

Deleted at cutover: `NotchNotch/Agent/` (all five files), `scripts/omp/`.

---

### Task 1: Activity state and plugin message protocol

**Files:**
- Create: `NotchNotch/Activity/ActivityState.swift`
- Create: `NotchNotch/Plugins/PluginMessage.swift`
- Test: `.temp/plugin-checks/messages/main.swift`

**Interfaces:**
- Produces: `ActivityState` (`working`, `waitingUser`, `waitingSubagent`, `completed`, `idle`; `isWaiting`), `SessionUpdate { id, state, label, title?, pid?, cwd?, alert: Bool? }`, `PluginMessage { .sessionUpdate(SessionUpdate), .sessionEnd(id:alert:) }`, `PluginEnvelope { plugin: String?, message }`, `PluginMessageDecoder.decode(_ data: Data) -> PluginEnvelope?`, `PluginMessageDecoder.legacyState(rawState:event:) -> ActivityState`, `PluginMessageDecoder.validatedPID(_:) -> Int?`, `JSONLineBuffer.append(_:) -> [Data]`.

- [ ] **Step 1: Write the failing test**

`.temp/plugin-checks/messages/main.swift`:

```swift
import Foundation

func check(_ ok: Bool, _ what: String) { print(ok ? "PASS" : "FAIL", what); if !ok { failures += 1 } }
var failures = 0
func json(_ s: String) -> Data { Data(s.utf8) }

// New schema
let u = PluginMessageDecoder.decode(json(#"{"type":"session.update","plugin":"co.x.y","id":"s1","state":"completed","label":"omp","title":"T","pid":4242,"cwd":"/w","alert":true}"#))
check(u == PluginEnvelope(plugin: "co.x.y", message: .sessionUpdate(SessionUpdate(id: "s1", state: .completed, label: "omp", title: "T", pid: 4242, cwd: "/w", alert: true))), "session.update decodes")
check(PluginMessageDecoder.decode(json(#"{"type":"session.update","id":"s1","state":"completed","label":"omp"}"#))?.message == .sessionUpdate(SessionUpdate(id: "s1", state: .completed, label: "omp", title: nil, pid: nil, cwd: nil, alert: false)), "alert defaults to false in new schema")
check(PluginMessageDecoder.decode(json(#"{"type":"session.update","id":"s1","state":"Busy","label":"omp"}"#)) == nil, "unknown state rejected")
check(PluginMessageDecoder.decode(json(#"{"type":"session.update","state":"working","label":"omp"}"#)) == nil, "missing id rejected")
check(PluginMessageDecoder.decode(json(#"{"type":"session.end","id":"s1","alert":true}"#))?.message == .sessionEnd(id: "s1", alert: true), "session.end decodes")
check(PluginMessageDecoder.decode(json(#"{"type":"nope"}"#)) == nil, "unknown type rejected")
check(PluginMessageDecoder.decode(json("[1,2]")) == nil, "non-object rejected")

// Legacy schema
let l = PluginMessageDecoder.decode(json(#"{"state":"waiting_user","agent":"claude","session_id":"abc","pid":99}"#))
check(l == PluginEnvelope(plugin: nil, message: .sessionUpdate(SessionUpdate(id: "abc", state: .waitingUser, label: "claude", title: nil, pid: 99, cwd: nil, alert: nil))), "legacy maps with alert nil")
check(PluginMessageDecoder.legacyState(rawState: "Working", event: "Stop") == .completed, "Stop event -> completed")
check(PluginMessageDecoder.legacyState(rawState: "waiting", event: "SubagentNotification") == .waitingSubagent, "waiting + subagent event")
check(PluginMessageDecoder.legacyState(rawState: "x", event: "PreToolUse") == .working, "PreToolUse -> working")
check(PluginMessageDecoder.legacyState(rawState: "x", event: "") == .idle, "unknown -> idle")
check(PluginMessageDecoder.decode(json(#"{"agent":"a"}"#))?.message == .sessionUpdate(SessionUpdate(id: "", state: .working, label: "a", title: nil, pid: nil, cwd: nil, alert: nil)), "legacy defaults: state Working, empty id")

// pid validation
check(PluginMessageDecoder.validatedPID(1) == nil, "pid 1 rejected")
check(PluginMessageDecoder.validatedPID(Int(Int32.max) + 1) == nil, "pid overflow rejected")
check(PluginMessageDecoder.validatedPID(500) == 500, "pid ok")

// Line buffer
var buffer = JSONLineBuffer()
check(buffer.append(json("{\"a\":1}\n{\"b\"")) == [json("{\"a\":1}")], "complete line returned, partial kept")
check(buffer.append(json(":2}\n\n")) == [json("{\"b\":2}")], "partial completed, empty line skipped")
var big = JSONLineBuffer()
check(big.append(Data(repeating: 0x41, count: JSONLineBuffer.maxLineBytes + 1)).isEmpty, "oversized partial yields nothing")
check(big.append(json("\n{\"c\":3}\n")) == [json("{\"c\":3}")], "oversized line dropped, next line kept")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mkdir -p .temp/plugin-checks/messages && swiftc NotchNotch/Activity/ActivityState.swift NotchNotch/Plugins/PluginMessage.swift .temp/plugin-checks/messages/main.swift -o .temp/plugin-checks/messages/run`
Expected: FAIL, `error: no such file or directory: 'NotchNotch/Activity/ActivityState.swift'`

- [ ] **Step 3: Write `ActivityState.swift`**

```swift
//
//  ActivityState.swift
//  NotchNotch
//
//  The session states every plugin reports. Pure, so `.temp/` scripts can
//  compile it; colours and labels live in ActivityState+Presentation.swift.
//

import Foundation

nonisolated enum ActivityState: String, Sendable, Equatable, CaseIterable {
    case working
    case waitingUser       // needs a human reply: permission, question, prompt
    case waitingSubagent   // waiting on a delegated child task
    case completed         // finished a turn or a task
    case idle

    var isWaiting: Bool {
        self == .waitingUser || self == .waitingSubagent
    }
}
```

- [ ] **Step 4: Write `PluginMessage.swift`**

```swift
//
//  PluginMessage.swift
//  NotchNotch
//
//  The one message schema plugins speak, over stdio (JSON lines) and over
//  HTTP (one object per POST). Pure, so `.temp/` scripts can compile it.
//

import Foundation

nonisolated struct SessionUpdate: Equatable, Sendable {
    var id: String
    var state: ActivityState
    var label: String
    var title: String?
    var pid: Int?
    var cwd: String?
    /// nil only for legacy HTTP bodies: the hub then alerts on the transitions
    /// the pre-plugin listener alerted on.
    var alert: Bool?
}

nonisolated enum PluginMessage: Equatable, Sendable {
    case sessionUpdate(SessionUpdate)
    case sessionEnd(id: String, alert: Bool)
}

nonisolated struct PluginEnvelope: Equatable, Sendable {
    /// Manifest id from an HTTP body. Ignored for stdio, where the pipe names the plugin.
    let plugin: String?
    let message: PluginMessage
}

nonisolated enum PluginMessageDecoder {

    static func decode(_ data: Data) -> PluginEnvelope? {
        guard let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let plugin = nonEmpty(dict["plugin"])
        guard let type = dict["type"] as? String else {
            return PluginEnvelope(plugin: plugin, message: .sessionUpdate(legacy(dict)))
        }
        switch type {
        case "session.update":
            guard let id = nonEmpty(dict["id"]),
                  let rawState = dict["state"] as? String,
                  let state = ActivityState(rawValue: rawState),
                  let label = nonEmpty(dict["label"]) else { return nil }
            return PluginEnvelope(plugin: plugin, message: .sessionUpdate(SessionUpdate(
                id: id,
                state: state,
                label: label,
                title: nonEmpty(dict["title"]),
                pid: validatedPID(dict["pid"]),
                cwd: nonEmpty(dict["cwd"]),
                alert: dict["alert"] as? Bool ?? false
            )))
        case "session.end":
            guard let id = nonEmpty(dict["id"]) else { return nil }
            return PluginEnvelope(plugin: plugin, message: .sessionEnd(id: id, alert: dict["alert"] as? Bool ?? false))
        default:
            return nil
        }
    }

    /// Bodies from hook scripts written against the pre-plugin listener. An
    /// empty id asks the hub to continue that label's most recent session.
    static func legacy(_ dict: [String: Any]) -> SessionUpdate {
        SessionUpdate(
            id: nonEmpty(dict["session_id"]) ?? "",
            state: legacyState(rawState: dict["state"] as? String ?? "Working", event: dict["event"] as? String ?? ""),
            label: nonEmpty(dict["agent"]) ?? "Agent",
            title: nonEmpty(dict["title"]),
            pid: validatedPID(dict["pid"]),
            cwd: nonEmpty(dict["cwd"]),
            alert: nil
        )
    }

    /// Deliberately fuzzy so different CLI hook scripts can post without a
    /// shared schema. `title` is free text and never decides state.
    static func legacyState(rawState: String, event: String) -> ActivityState {
        let state = rawState.lowercased()
        let lowerEvent = event.lowercased()
        if ["waitingsubagent", "waiting_subagent", "subagent", "subagents", "sub"].contains(state) {
            return .waitingSubagent
        }
        if ["waitinguser", "waiting_user", "reply", "waiting_reply", "action"].contains(state) {
            return .waitingUser
        }
        if state == "waiting" || event == "Notification" {
            return lowerEvent.contains("subagent") ? .waitingSubagent : .waitingUser
        }
        if state == "ended" || state == "completed" || event == "Stop" || event == "SessionEnd" {
            return .completed
        }
        if state == "working" || state == "auto" || event == "PreToolUse" || event == "UserPromptSubmit" {
            return .working
        }
        return .idle
    }

    /// `pid_t` is 32-bit, so an out-of-range JSON number must be rejected, not
    /// trapped on. 0 and 1 are the kernel and launchd, never an agent.
    static func validatedPID(_ value: Any?) -> Int? {
        guard let raw = value as? Int, let pid = Int32(exactly: raw), pid > 1 else { return nil }
        return Int(pid)
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

/// Splits a plugin's stdout into lines. A runaway line is dropped whole rather
/// than buffered without bound.
nonisolated struct JSONLineBuffer: Sendable {
    static let maxLineBytes = 256 * 1024
    private var pending = Data()
    private var discarding = false

    mutating func append(_ chunk: Data) -> [Data] {
        var lines: [Data] = []
        for byte in chunk {
            if byte == UInt8(ascii: "\n") {
                if !discarding && !pending.isEmpty { lines.append(pending) }
                pending.removeAll(keepingCapacity: true)
                discarding = false
            } else if !discarding {
                pending.append(byte)
                if pending.count > Self.maxLineBytes {
                    pending.removeAll()
                    discarding = true
                }
            }
        }
        return lines
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swiftc NotchNotch/Activity/ActivityState.swift NotchNotch/Plugins/PluginMessage.swift .temp/plugin-checks/messages/main.swift -o .temp/plugin-checks/messages/run && .temp/plugin-checks/messages/run`
Expected: every line `PASS`, last line `ALL PASS`.

- [ ] **Step 6: Build the app**

Run: `xcodebuild -scheme NotchNotch -configuration Debug -derivedDataPath build/DerivedData build 2>&1 | grep -E 'error:|BUILD (SUCCEEDED|FAILED)'`
Expected: `** BUILD SUCCEEDED **` (new files are unused so far; the folder is a synchronized group, no pbxproj edit).

- [ ] **Step 7: Commit**

```bash
git add NotchNotch/Activity/ActivityState.swift NotchNotch/Plugins/PluginMessage.swift
git commit -m "feat(plugins): add activity state and plugin message protocol"
```

---

### Task 2: Plugin manifest, preferences and migration

**Files:**
- Create: `NotchNotch/Plugins/PluginManifest.swift`
- Create: `NotchNotch/Plugins/PluginPreferences.swift`
- Modify: `docs/superpowers/specs/2026-11-10-process-plugins-design.md` (Migration section)
- Test: `.temp/plugin-checks/manifest/main.swift`

**Interfaces:**
- Produces: `PluginManifest { id, name: [String: String], version, kind: Kind (.managed/.external), executable: String?, apiVersion }`, `PluginManifest.currentAPIVersion = 1`, `PluginManifest.decode(_ data: Data) -> Result<PluginManifest, PluginManifestError>`, `PluginManifest.load(from: URL) -> Result<PluginManifest, PluginManifestError>`, `PluginManifest.displayName(isChinese:) -> String`, `PluginManifestError: Error, Equatable, CustomStringConvertible`, `PluginPreferences.httpEnabledKey`, `PluginPreferences.agentsPluginID`, `PluginPreferences.ompPluginID`, `PluginPreferences.enabledKey(_:)`, `PluginPreferences.isEnabled(_:in:)`, `PluginPreferences.isHTTPEnabled(in:)`, `PluginPreferences.migrate(defaults:installedPluginIDs:)`.

- [ ] **Step 1: Write the failing test**

`.temp/plugin-checks/manifest/main.swift`:

```swift
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "PASS" : "FAIL", what); if !ok { failures += 1 } }
func manifest(_ s: String) -> Result<PluginManifest, PluginManifestError> { PluginManifest.decode(Data(s.utf8)) }

let good = manifest(#"{"id":"co.jianyuelab.notchnotch.agents","name":{"en":"Agent Detection","zh-Hans":"Agent 识别"},"version":"27.2.0","kind":"managed","executable":"agents","apiVersion":1}"#)
check((try? good.get())?.executable == "agents", "managed manifest decodes")
check((try? good.get())?.displayName(isChinese: true) == "Agent 识别", "zh name")
check((try? good.get())?.displayName(isChinese: false) == "Agent Detection", "en name")
check(manifest(#"{"id":"co.x.omp","name":{"en":"omp"},"version":"1","kind":"external","apiVersion":1}"#).map(\.kind) == .success(.external), "external without executable")
check((try? manifest(#"{"id":"co.x.omp","name":{"en":"omp"},"version":"1","kind":"external","apiVersion":1}"#).get())?.displayName(isChinese: true) == "omp", "zh falls back to en")
check(manifest("{").failureValue == .invalidJSON, "bad json")
check(manifest(#"{"name":{"en":"x"},"version":"1","kind":"managed","executable":"a","apiVersion":1}"#).failureValue == .missingField("id"), "missing id")
check(manifest(#"{"id":"Bad ID","name":{"en":"x"},"version":"1","kind":"managed","executable":"a","apiVersion":1}"#).failureValue == .badID("Bad ID"), "bad id")
check(manifest(#"{"id":"co.x.y","name":{"en":"x"},"version":"1","kind":"managed","executable":"a","apiVersion":2}"#).failureValue == .unsupportedAPI(2), "api mismatch")
check(manifest(#"{"id":"co.x.y","name":{"en":"x"},"version":"1","kind":"managed","apiVersion":1}"#).failureValue == .managedWithoutExecutable, "managed needs executable")
check(manifest(#"{"id":"co.x.y","name":{"en":"x"},"version":"1","kind":"managed","executable":"../evil","apiVersion":1}"#).failureValue == .executableEscapes("../evil"), "executable path escape")
check(manifest(#"{"id":"co.x.y","name":{"en":"x"},"version":"1","kind":"plugin","apiVersion":1}"#).failureValue == .badKind("plugin"), "bad kind")
check(manifest(#"{"id":"co.x.y","name":{},"version":"1","kind":"external","apiVersion":1}"#).failureValue == .missingField("name.en"), "name needs en")

// Preferences and migration
let suite = "notchnotch.plugin-checks.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
check(PluginPreferences.isEnabled("co.x.y", in: defaults), "absent key = enabled")
check(PluginPreferences.isHTTPEnabled(in: defaults), "http defaults on")
defaults.set(false, forKey: "co.jianyuelab.NotchNotch.agentMonitoringEnabled")
defaults.set(true, forKey: "co.jianyuelab.NotchNotch.agentProcessScanningEnabled")
PluginPreferences.migrate(defaults: defaults, installedPluginIDs: [])
check(!PluginPreferences.isHTTPEnabled(in: defaults), "monitoring=false -> http off")
check(defaults.object(forKey: "co.jianyuelab.NotchNotch.agentMonitoringEnabled") == nil, "monitoring key removed")
check(defaults.object(forKey: "co.jianyuelab.NotchNotch.agentProcessScanningEnabled") != nil, "scanning key kept until agent plugin installed")
defaults.set(false, forKey: "co.jianyuelab.NotchNotch.agentProcessScanningEnabled")
PluginPreferences.migrate(defaults: defaults, installedPluginIDs: [PluginPreferences.agentsPluginID])
check(!PluginPreferences.isEnabled(PluginPreferences.agentsPluginID, in: defaults), "scanning=false -> agent plugin disabled")
check(defaults.object(forKey: "co.jianyuelab.NotchNotch.agentProcessScanningEnabled") == nil, "scanning key removed after migration")
UserDefaults.standard.removePersistentDomain(forName: suite)

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)

extension Result {
    var failureValue: Failure? { if case .failure(let e) = self { return e }; return nil }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mkdir -p .temp/plugin-checks/manifest && swiftc NotchNotch/Plugins/PluginManifest.swift NotchNotch/Plugins/PluginPreferences.swift .temp/plugin-checks/manifest/main.swift -o .temp/plugin-checks/manifest/run`
Expected: FAIL, no such file `PluginManifest.swift`.

- [ ] **Step 3: Write `PluginManifest.swift`**

```swift
//
//  PluginManifest.swift
//  NotchNotch
//
//  `<plugin dir>/manifest.json`. Pure, so `.temp/` scripts can compile it.
//

import Foundation

nonisolated struct PluginManifest: Equatable, Sendable {
    enum Kind: String, Sendable {
        case managed    // the core launches `executable`
        case external   // another program runs it; the core only registers it
    }

    static let currentAPIVersion = 1

    let id: String
    let name: [String: String]
    let version: String
    let kind: Kind
    let executable: String?
    let apiVersion: Int

    func displayName(isChinese: Bool) -> String {
        (isChinese ? name["zh-Hans"] : nil) ?? name["en"] ?? id
    }

    static func load(from url: URL) -> Result<PluginManifest, PluginManifestError> {
        guard let data = try? Data(contentsOf: url) else { return .failure(.unreadable) }
        return decode(data)
    }

    static func decode(_ data: Data) -> Result<PluginManifest, PluginManifestError> {
        guard let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(.invalidJSON)
        }
        guard let id = dict["id"] as? String else { return .failure(.missingField("id")) }
        guard id.range(of: #"^[a-z0-9]+(\.[a-z0-9-]+)+$"#, options: .regularExpression) != nil else {
            return .failure(.badID(id))
        }
        guard let name = dict["name"] as? [String: String] else { return .failure(.missingField("name")) }
        guard name["en"]?.isEmpty == false else { return .failure(.missingField("name.en")) }
        guard let version = dict["version"] as? String else { return .failure(.missingField("version")) }
        guard let rawKind = dict["kind"] as? String else { return .failure(.missingField("kind")) }
        guard let kind = Kind(rawValue: rawKind) else { return .failure(.badKind(rawKind)) }
        guard let apiVersion = dict["apiVersion"] as? Int else { return .failure(.missingField("apiVersion")) }
        guard apiVersion == currentAPIVersion else { return .failure(.unsupportedAPI(apiVersion)) }

        let executable = dict["executable"] as? String
        if kind == .managed {
            guard let executable, !executable.isEmpty else { return .failure(.managedWithoutExecutable) }
            // A plain file name inside the plugin directory, never a path out of it.
            guard !executable.contains("/"), executable != ".", executable != ".." else {
                return .failure(.executableEscapes(executable))
            }
        }
        return .success(PluginManifest(
            id: id, name: name, version: version, kind: kind,
            executable: kind == .managed ? executable : nil,
            apiVersion: apiVersion
        ))
    }
}

nonisolated enum PluginManifestError: Error, Equatable, Sendable, CustomStringConvertible {
    case unreadable
    case invalidJSON
    case missingField(String)
    case badID(String)
    case badKind(String)
    case unsupportedAPI(Int)
    case managedWithoutExecutable
    case executableEscapes(String)
    case duplicateID(String)

    var description: String {
        switch self {
        case .unreadable: return "manifest.json missing or unreadable"
        case .invalidJSON: return "manifest.json is not a JSON object"
        case .missingField(let field): return "missing field \(field)"
        case .badID(let id): return "invalid id \(id)"
        case .badKind(let kind): return "unknown kind \(kind)"
        case .unsupportedAPI(let version): return "apiVersion \(version) is not supported (expected \(PluginManifest.currentAPIVersion))"
        case .managedWithoutExecutable: return "managed plugin without executable"
        case .executableEscapes(let path): return "executable must be a file name, got \(path)"
        case .duplicateID(let id): return "duplicate id \(id)"
        }
    }
}
```

- [ ] **Step 4: Write `PluginPreferences.swift`**

```swift
//
//  PluginPreferences.swift
//  NotchNotch
//
//  UserDefaults keys for plugins and the one-time move off the pre-plugin
//  agent settings. Pure, so `.temp/` scripts can compile it.
//

import Foundation

nonisolated enum PluginPreferences {
    static let httpEnabledKey = "co.jianyuelab.NotchNotch.httpListenerEnabled"
    static let agentsPluginID = "co.jianyuelab.notchnotch.agents"
    static let ompPluginID = "co.jianyuelab.notchnotch.omp"

    static let legacyMonitoringKey = "co.jianyuelab.NotchNotch.agentMonitoringEnabled"
    static let legacyScanningKey = "co.jianyuelab.NotchNotch.agentProcessScanningEnabled"

    static func enabledKey(_ pluginID: String) -> String {
        "co.jianyuelab.NotchNotch.plugin.\(pluginID).enabled"
    }

    /// Installing a plugin is the intent to run it, so an absent key means enabled.
    static func isEnabled(_ pluginID: String, in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: enabledKey(pluginID)) as? Bool ?? true
    }

    static func isHTTPEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: httpEnabledKey) as? Bool ?? true
    }

    /// The scanning key is kept until the agent plugin is installed, so its
    /// choice still applies when the plugin arrives after the upgrade.
    static func migrate(defaults: UserDefaults, installedPluginIDs: Set<String>) {
        if let monitoring = defaults.object(forKey: legacyMonitoringKey) as? Bool {
            defaults.set(monitoring, forKey: httpEnabledKey)
            defaults.removeObject(forKey: legacyMonitoringKey)
        }
        if let scanning = defaults.object(forKey: legacyScanningKey) as? Bool,
           installedPluginIDs.contains(agentsPluginID) {
            defaults.set(scanning, forKey: enabledKey(agentsPluginID))
            defaults.removeObject(forKey: legacyScanningKey)
        }
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swiftc NotchNotch/Plugins/PluginManifest.swift NotchNotch/Plugins/PluginPreferences.swift .temp/plugin-checks/manifest/main.swift -o .temp/plugin-checks/manifest/run && .temp/plugin-checks/manifest/run`
Expected: `ALL PASS`.

- [ ] **Step 6: Align the spec's Migration section with the kept scanning key**

In `docs/superpowers/specs/2026-11-10-process-plugins-design.md`, replace the line `- Both old keys are deleted afterwards.` with:

```markdown
- `agentMonitoringEnabled` is deleted after it is applied.
- `agentProcessScanningEnabled` is deleted once the agent plugin is installed and the value applied.
```

- [ ] **Step 7: Build and commit**

Run: `xcodebuild -scheme NotchNotch -configuration Debug -derivedDataPath build/DerivedData build 2>&1 | grep -E 'error:|BUILD (SUCCEEDED|FAILED)'`
Expected: `** BUILD SUCCEEDED **`

```bash
git add NotchNotch/Plugins/PluginManifest.swift NotchNotch/Plugins/PluginPreferences.swift docs/superpowers/specs/2026-11-10-process-plugins-design.md
git commit -m "feat(plugins): add manifest validation and settings migration"
```

---

### Task 3: Activity rules and restart policy

**Files:**
- Create: `NotchNotch/Activity/ActivityRules.swift`
- Create: `NotchNotch/Plugins/RestartPolicy.swift`
- Test: `.temp/plugin-checks/rules/main.swift`

**Interfaces:**
- Consumes: `ActivityState` (Task 1).
- Produces: `ActivitySource { .managed, .external, .http }`, `ActivitySession { key, pluginID, sessionID, source, state, label, title, pid?, cwd, lastUpdated; id }`, `ActivityRules.key(pluginID:sessionID:) -> String`, `ActivityRules.visible(_:now:) -> [ActivitySession]`, `ActivityRules.active(_:) -> ActivitySession?`, `ActivityRules.shouldAlert(requested:previous:new:) -> Bool`, `ActivityRules.alertDuration(for:) -> TimeInterval`, `ActivityRules.explicitHold = 180`, `RestartPolicy.recordExit(at:) -> RestartPolicy.Decision (.restart(after:) / .crashed)`.

- [ ] **Step 1: Write the failing test**

`.temp/plugin-checks/rules/main.swift`:

```swift
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "PASS" : "FAIL", what); if !ok { failures += 1 } }
let now = Date(timeIntervalSince1970: 1_000_000)
func session(_ id: String, _ source: ActivitySource, _ state: ActivityState, pid: Int?, age: TimeInterval) -> ActivitySession {
    ActivitySession(pluginID: "p", sessionID: id, source: source, state: state, label: "L", title: "", pid: pid, cwd: "", lastUpdated: now.addingTimeInterval(-age))
}

check(ActivityRules.key(pluginID: "co.x", sessionID: "s") == "co.x/s", "key format")

// Pid dedup
let scanned = session("scan", .managed, .waitingUser, pid: 10, age: 1)
let hook = session("hook", .external, .working, pid: 10, age: 5)
check(ActivityRules.visible([scanned, hook], now: now).map(\.sessionID) == ["hook"], "fresh explicit hides managed twin")
let staleHook = session("hook", .http, .completed, pid: 10, age: 181)
check(Set(ActivityRules.visible([scanned, staleHook], now: now).map(\.sessionID)) == ["scan", "hook"], "stale explicit no longer hides")
let otherPid = session("hook", .external, .working, pid: 11, age: 5)
check(ActivityRules.visible([scanned, otherPid], now: now).count == 2, "different pid not deduped")
let noPid = session("hook", .external, .working, pid: nil, age: 5)
check(ActivityRules.visible([scanned, noPid], now: now).count == 2, "explicit without pid hides nothing")

// Priority
let a = session("a", .external, .working, pid: nil, age: 1)
let b = session("b", .external, .waitingUser, pid: nil, age: 50)
let c = session("c", .external, .completed, pid: nil, age: 0)
check(ActivityRules.active([a, b, c])?.sessionID == "b", "waitingUser outranks recency")
check(ActivityRules.active([a, c])?.sessionID == "a", "working outranks completed")
check(ActivityRules.active([session("i", .external, .idle, pid: nil, age: 3)])?.sessionID == "i", "idle-only falls back to most recent")
let t1 = session("x", .external, .working, pid: nil, age: 1)
let t2 = session("y", .external, .working, pid: nil, age: 1)
check(ActivityRules.active([t2, t1])?.sessionID == "x", "tie broken by key")

// Alert rule
check(ActivityRules.shouldAlert(requested: true, previous: .completed, new: .completed), "explicit true alerts")
check(!ActivityRules.shouldAlert(requested: false, previous: .working, new: .waitingUser), "explicit false never alerts")
check(ActivityRules.shouldAlert(requested: nil, previous: nil, new: .waitingUser), "legacy: first waitingUser alerts")
check(!ActivityRules.shouldAlert(requested: nil, previous: .waitingUser, new: .waitingUser), "legacy: repeat waitingUser silent")
check(ActivityRules.shouldAlert(requested: nil, previous: .working, new: .completed), "legacy: working -> completed alerts")
check(!ActivityRules.shouldAlert(requested: nil, previous: nil, new: .completed), "legacy: completed with no history silent")
check(!ActivityRules.shouldAlert(requested: nil, previous: .idle, new: .working), "legacy: working never alerts")
check(ActivityRules.alertDuration(for: .waitingUser) == 7 && ActivityRules.alertDuration(for: .completed) == 3.5, "durations")

// Restart policy
var policy = RestartPolicy()
let t0 = Date(timeIntervalSince1970: 0)
check(policy.recordExit(at: t0) == .restart(after: 1), "1st exit: 1s")
check(policy.recordExit(at: t0.addingTimeInterval(10)) == .restart(after: 2), "2nd exit: 2s")
check(policy.recordExit(at: t0.addingTimeInterval(20)) == .restart(after: 4), "3rd exit: 4s")
check(policy.recordExit(at: t0.addingTimeInterval(30)) == .restart(after: 8), "4th exit: 8s")
check(policy.recordExit(at: t0.addingTimeInterval(40)) == .crashed, "5th exit within window: crashed")
var spaced = RestartPolicy()
for i in 0..<10 { _ = spaced.recordExit(at: t0.addingTimeInterval(Double(i) * 601)) }
check(spaced.recordExit(at: t0.addingTimeInterval(10 * 601)) == .restart(after: 1), "exits outside the window are forgotten")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mkdir -p .temp/plugin-checks/rules && swiftc NotchNotch/Activity/ActivityState.swift NotchNotch/Activity/ActivityRules.swift NotchNotch/Plugins/RestartPolicy.swift .temp/plugin-checks/rules/main.swift -o .temp/plugin-checks/rules/run`
Expected: FAIL, no such file `ActivityRules.swift`.

- [ ] **Step 3: Write `ActivityRules.swift`**

```swift
//
//  ActivityRules.swift
//  NotchNotch
//
//  Which sessions show, which one the island follows, and when to alert.
//  Pure, so `.temp/` scripts can compile it.
//

import Foundation

nonisolated enum ActivitySource: Sendable, Equatable {
    case managed    // a plugin the core launched (inferred state)
    case external   // a registered external plugin over HTTP (reported state)
    case http       // a body without `plugin`: hook scripts, curl
}

nonisolated struct ActivitySession: Identifiable, Equatable, Sendable {
    let pluginID: String
    let sessionID: String
    let source: ActivitySource
    var state: ActivityState
    var label: String
    var title: String
    var pid: Int?
    var cwd: String
    var lastUpdated: Date

    var key: String { ActivityRules.key(pluginID: pluginID, sessionID: sessionID) }
    var id: String { key }
}

nonisolated enum ActivityRules {

    /// How long an explicit report keeps a scanned twin of the same process hidden.
    static let explicitHold: TimeInterval = 180

    /// Namespaced so one plugin can never overwrite another's sessions.
    static func key(pluginID: String, sessionID: String) -> String {
        "\(pluginID)/\(sessionID)"
    }

    /// A managed session is hidden while an external or HTTP session reports
    /// the same pid and was updated within `explicitHold`: the report is exact,
    /// the scan is a guess, and a frozen guess would outrank it (REPLY over BUSY).
    static func visible(_ sessions: [ActivitySession], now: Date) -> [ActivitySession] {
        let explicitPIDs = Set(sessions.compactMap { session -> Int? in
            guard session.source != .managed, now.timeIntervalSince(session.lastUpdated) < explicitHold else { return nil }
            return session.pid
        })
        return sessions.filter { session in
            guard session.source == .managed, let pid = session.pid else { return true }
            return !explicitPIDs.contains(pid)
        }
    }

    /// Highest-priority state wins; within a state the most recent update.
    /// The key breaks ties, so the pick never flickers between equal sessions.
    static func active(_ sessions: [ActivitySession]) -> ActivitySession? {
        let byRecency = sessions.sorted {
            $0.lastUpdated != $1.lastUpdated ? $0.lastUpdated > $1.lastUpdated : $0.key < $1.key
        }
        for state in [ActivityState.waitingUser, .waitingSubagent, .working, .completed] {
            if let match = byRecency.first(where: { $0.state == state }) { return match }
        }
        return byRecency.first
    }

    /// Plugins decide for themselves. Legacy bodies (`requested == nil`) alert
    /// on a transition only, so a hook repeating a state never re-beeps.
    static func shouldAlert(requested: Bool?, previous: ActivityState?, new: ActivityState) -> Bool {
        if let requested { return requested }
        switch new {
        case .waitingUser: return previous != .waitingUser
        case .waitingSubagent: return previous != .waitingSubagent
        case .completed: return previous == .working || previous?.isWaiting == true
        case .working, .idle: return false
        }
    }

    static func alertDuration(for state: ActivityState) -> TimeInterval {
        state == .waitingUser ? 7.0 : 3.5
    }
}
```

- [ ] **Step 4: Write `RestartPolicy.swift`**

```swift
//
//  RestartPolicy.swift
//  NotchNotch
//
//  Backoff for a managed plugin that exits. Pure, so `.temp/` scripts can
//  compile it.
//

import Foundation

nonisolated struct RestartPolicy: Sendable {
    enum Decision: Equatable, Sendable {
        case restart(after: TimeInterval)
        case crashed
    }

    static let delays: [TimeInterval] = [1, 2, 4, 8]
    static let maxExits = 5
    static let window: TimeInterval = 600

    private var exits: [Date] = []

    /// A plugin that keeps dying stops being restarted until it is re-enabled;
    /// otherwise a broken binary would spin forever.
    mutating func recordExit(at now: Date) -> Decision {
        exits = exits.filter { now.timeIntervalSince($0) < Self.window } + [now]
        if exits.count >= Self.maxExits { return .crashed }
        return .restart(after: Self.delays[min(exits.count - 1, Self.delays.count - 1)])
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swiftc NotchNotch/Activity/ActivityState.swift NotchNotch/Activity/ActivityRules.swift NotchNotch/Plugins/RestartPolicy.swift .temp/plugin-checks/rules/main.swift -o .temp/plugin-checks/rules/run && .temp/plugin-checks/rules/run`
Expected: `ALL PASS`.

- [ ] **Step 6: Build and commit**

Run the Debug build; expected `** BUILD SUCCEEDED **`.

```bash
git add NotchNotch/Activity/ActivityRules.swift NotchNotch/Plugins/RestartPolicy.swift
git commit -m "feat(plugins): add session visibility, priority, alert and restart rules"
```

---

### Task 4: ActivityHub, focus and presentation

**Files:**
- Create: `NotchNotch/Activity/ActivityState+Presentation.swift`
- Create: `NotchNotch/Activity/ActivityFocus.swift`
- Create: `NotchNotch/Activity/ActivityHub.swift`
- Modify: `NotchNotch/Support/Log.swift` (add `plugins` category)
- Modify: `NotchNotch/App/NotchConfiguration.swift:135-142`

**Interfaces:**
- Consumes: Tasks 1 and 3.
- Produces: `ActivityState.displayName/shortTag/iconName/color/colorMuted`, `ActivityFocus.focus(pid: Int?)`, `ActivityFocus.isProcessAlive(_:) -> Bool`, `ActivityAlert { id, sessionKey, label, state, title, pid?, timestamp }`, `ActivityHub.shared` with `@Published sessions: [String: ActivitySession]`, `activeSession`, `currentAlert`, `isShowingAlert`; `isWorking`, `isWaitingUser`, `isWaitingSubagent`; `apply(_ message: PluginMessage, pluginID: String, source: ActivitySource)`, `removeSessions(of pluginID: String)`, `removeSessions(from sources: Set<ActivitySource>)`, `triggerAlert(_:autoDismissAfter:)`, `dismissAlert()`, `focusActiveSession()`. `Log.plugins`. `NotchConfiguration.activityInactivityTimeout`, `.activityMaxExplicitSessions`, `.pluginHTTPRequestTimeout`.

This task adds code that nothing calls yet; the old `AgentHarnessController` keeps running until Task 6.

- [ ] **Step 1: Add the log category**

In `NotchNotch/Support/Log.swift`, after `static let location  = …`:

```swift
    static let plugins   = Logger(subsystem: subsystem, category: "plugins")
```

- [ ] **Step 2: Add the new configuration names next to the old ones**

In `NotchNotch/App/NotchConfiguration.swift`, after line 142 (`static let agentHTTPRequestTimeout…`), add:

```swift
    /// An explicit session that stops reporting (interrupted agent, no Stop) is dropped after this.
    static let activityInactivityTimeout: TimeInterval = 15 * 60

    /// Oldest external/HTTP sessions are evicted beyond this. Any local process can mint ids.
    static let activityMaxExplicitSessions = 32

    /// A connection that has not delivered a full request by then is closed.
    static let pluginHTTPRequestTimeout: TimeInterval = 5
```

(The three `agent*` constants are deleted in Task 6 together with their last users.)

- [ ] **Step 3: Write `ActivityState+Presentation.swift`**

Copy the presentation members of `AgentState` (`NotchNotch/Agent/AgentModels.swift:23-73`) unchanged into an extension:

```swift
//
//  ActivityState+Presentation.swift
//  NotchNotch
//

import SwiftUI

extension ActivityState {
    var displayName: String {
        let isZh = LocalizationManager.shared.isChinese
        switch self {
        case .working: return isZh ? "运行中" : "Working"
        case .waitingUser: return isZh ? "等待回复" : "Reply Needed"
        case .waitingSubagent: return isZh ? "子任务执行中" : "Subagent Active"
        case .completed: return isZh ? "已完成" : "Completed"
        case .idle: return isZh ? "空闲" : "Idle"
        }
    }

    var shortTag: String {
        let isZh = LocalizationManager.shared.isChinese
        switch self {
        case .working: return isZh ? "忙碌" : "BUSY"
        case .waitingUser: return isZh ? "回复" : "REPLY"
        case .waitingSubagent: return isZh ? "子项" : "SUB"
        case .completed: return isZh ? "完成" : "DONE"
        case .idle: return isZh ? "空闲" : "IDLE"
        }
    }

    var iconName: String {
        switch self {
        case .working: return "sparkles"
        case .waitingUser: return "exclamationmark.bubble.fill"
        case .waitingSubagent: return "arrow.triangle.branch"
        case .completed: return "checkmark.circle.fill"
        case .idle: return "circle"
        }
    }

    var color: Color {
        switch self {
        case .working: return JYLTheme.info
        case .waitingUser: return JYLTheme.primary // Amber
        case .waitingSubagent: return JYLTheme.chart3 // Purple / Lavender (#a78bfa)
        case .completed: return JYLTheme.success
        case .idle: return JYLTheme.textMuted
        }
    }

    var colorMuted: Color {
        switch self {
        case .working: return JYLTheme.infoMuted
        case .waitingUser: return JYLTheme.primaryMuted
        case .waitingSubagent: return Color(hex: "#a78bfa", opacity: 0.20)
        case .completed: return JYLTheme.successMuted
        case .idle: return Color.white.opacity(0.1)
        }
    }
}
```

- [ ] **Step 4: Write `ActivityFocus.swift`**

Move the focus half of `DarwinProcessHelper` (`AgentHarnessController.swift`, enum starting at line 18) into a new enum. Keep these members verbatim, including their comments: `getParentPID(of:)`, `findGUIApp(for:)`, `resolveTmuxClientGUIApp(for:)`, `findGUIAppDirect(for:)`, `isProcessAlive(_:)`. Do **not** copy `getProcessCWD` or `openFilePath` (they move to the agent plugin or disappear). Replace `fallbackTerminalApp(hint:)` and add `focus(pid:)`:

```swift
//
//  ActivityFocus.swift
//  NotchNotch
//
//  Brings the terminal or editor hosting a session's process to the front.
//  Plugins only report a pid; turning it into an app lives here so every
//  plugin focuses the same way.
//

import AppKit
import Darwin.libproc

nonisolated enum ActivityFocus {

    // getParentPID(of:), findGUIApp(for:), resolveTmuxClientGUIApp(for:),
    // findGUIAppDirect(for:) and isProcessAlive(_:):
    // moved verbatim from DarwinProcessHelper in AgentHarnessController.swift.

    /// First running known terminal or editor, in preference order.
    static func fallbackTerminalApp() -> NSRunningApplication? {
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        for bundleID in knownTerminalBundleIDs {
            if let app = running.first(where: { $0.bundleIdentifier?.caseInsensitiveCompare(bundleID) == .orderedSame }) {
                return app
            }
        }
        return nil
    }

    /// The tree climb can wait on tmux, so it runs off the main actor.
    static func focus(pid: Int?) {
        let pid32 = pid.flatMap { pid_t(exactly: $0) }
        Task.detached(priority: .userInitiated) {
            let hostPid = pid32.flatMap { findGUIApp(for: $0)?.processIdentifier }
            await MainActor.run {
                if let hostPid, let app = NSRunningApplication(processIdentifier: hostPid) {
                    app.activate(options: [.activateIgnoringOtherApps])
                    return
                }
                fallbackTerminalApp()?.activate(options: [.activateIgnoringOtherApps])
            }
        }
    }
}
```

`knownTerminals` is replaced by a plain bundle-id list (the `names` were only for the HTTP `terminal` hint, which is gone):

```swift
    /// Terminals and editors the fallback may activate, in preference order.
    private static let knownTerminalBundleIDs = [
        "com.mitchellh.ghostty", "dev.zed.Zed", "com.googlecode.iterm2", "com.apple.Terminal",
        "dev.warp.Warp-Stable", "com.todesktop.230313mzl4w4u92", "com.microsoft.VSCode",
        "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm",
    ]
```


- [ ] **Step 5: Write `ActivityHub.swift`**

```swift
//
//  ActivityHub.swift
//  NotchNotch
//
//  Every session any plugin reports, the one the island follows, and the
//  alert banner. Knows nothing about particular agents: a session is a key,
//  a state, a label, a title and maybe a pid.
//

import AppKit
import Combine
import SwiftUI

struct ActivityAlert: Equatable, Sendable {
    let id = UUID()
    let sessionKey: String
    let label: String
    let state: ActivityState
    /// Conversation title; empty when the plugin reported none.
    let title: String
    let pid: Int?
    let timestamp: Date
}

@MainActor
final class ActivityHub: ObservableObject {

    static let shared = ActivityHub()

    @Published private(set) var sessions: [String: ActivitySession] = [:]
    @Published private(set) var activeSession: ActivitySession?
    @Published private(set) var currentAlert: ActivityAlert?
    @Published private(set) var isShowingAlert = false

    private var dismissTimer: Timer?
    private var pruneTimer: Timer?
    private static let completedSessionLimit: TimeInterval = 90

    var isWorking: Bool { activeSession?.state == .working }
    var isWaitingUser: Bool { activeSession?.state == .waitingUser }
    var isWaitingSubagent: Bool { activeSession?.state == .waitingSubagent }

    private init() {
        // Also re-evaluates pid dedup, whose hold expires with time, not with a message.
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.prune() }
        }
    }

    // MARK: - Ingestion

    func apply(_ message: PluginMessage, pluginID: String, source: ActivitySource) {
        switch message {
        case .sessionUpdate(let update):
            apply(update, pluginID: pluginID, source: source)
        case .sessionEnd(let sessionID, let alert):
            end(ActivityRules.key(pluginID: pluginID, sessionID: sessionID), alert: alert)
        }
    }

    private func apply(_ update: SessionUpdate, pluginID: String, source: ActivitySource) {
        let sessionID = update.id.isEmpty ? continuedSessionID(label: update.label, pluginID: pluginID) : update.id
        let key = ActivityRules.key(pluginID: pluginID, sessionID: sessionID)
        let previous = sessions[key]

        var session = previous ?? ActivitySession(
            pluginID: pluginID, sessionID: sessionID, source: source, state: update.state,
            label: update.label, title: "", pid: nil, cwd: "", lastUpdated: Date()
        )
        session.state = update.state
        session.label = update.label
        if let title = update.title { session.title = title }
        if let pid = update.pid { session.pid = pid }
        if let cwd = update.cwd { session.cwd = cwd }
        session.lastUpdated = Date()
        sessions[key] = session

        if source != .managed { evictExcessExplicitSessions(keeping: key) }
        recomputeActive()

        Log.plugins.notice("session \(key, privacy: .public) -> \(update.state.rawValue, privacy: .public)")

        // A managed twin hidden by an explicit report must not alert over it.
        let isVisible = ActivityRules.visible(Array(sessions.values), now: Date()).contains { $0.key == key }
        if isVisible, ActivityRules.shouldAlert(requested: update.alert, previous: previous?.state, new: update.state) {
            triggerAlert(alert(for: session, state: session.state), autoDismissAfter: ActivityRules.alertDuration(for: session.state))
            if session.state == .waitingUser { NSSound.beep() }
        } else if update.state == .working, isShowingAlert,
                  currentAlert?.state.isWaiting == true, currentAlert?.sessionKey == key {
            // The user answered, or the subagent finished: the reply banner is stale.
            dismissAlert()
        }
    }

    private func end(_ key: String, alert: Bool) {
        guard let session = sessions.removeValue(forKey: key) else { return }
        recomputeActive()
        if alert {
            triggerAlert(self.alert(for: session, state: .completed), autoDismissAfter: ActivityRules.alertDuration(for: .completed))
        } else if currentAlert?.sessionKey == key {
            dismissAlert()
        }
    }

    /// A session without an id continues this plugin's most recent session of
    /// the same label. Dictionary order is arbitrary, so pick by recency.
    private func continuedSessionID(label: String, pluginID: String) -> String {
        sessions.values
            .filter { $0.pluginID == pluginID && $0.label.caseInsensitiveCompare(label) == .orderedSame }
            .max(by: { $0.lastUpdated < $1.lastUpdated })?
            .sessionID ?? "default-\(label)"
    }

    private func alert(for session: ActivitySession, state: ActivityState) -> ActivityAlert {
        ActivityAlert(sessionKey: session.key, label: session.label, state: state, title: session.title, pid: session.pid, timestamp: Date())
    }

    // MARK: - Removal

    func removeSessions(of pluginID: String) {
        removeSessions { $0.pluginID == pluginID }
    }

    func removeSessions(from sources: Set<ActivitySource>) {
        removeSessions { sources.contains($0.source) }
    }

    private func removeSessions(where shouldRemove: (ActivitySession) -> Bool) {
        let keys = sessions.values.filter(shouldRemove).map(\.key)
        guard !keys.isEmpty else { return }
        for key in keys { sessions.removeValue(forKey: key) }
        if let alertKey = currentAlert?.sessionKey, keys.contains(alertKey) { dismissAlert() }
        recomputeActive()
    }

    private func evictExcessExplicitSessions(keeping keep: String) {
        let explicit = sessions.values.filter { $0.source != .managed && $0.key != keep }
        let excess = explicit.count + 1 - NotchConfiguration.activityMaxExplicitSessions
        guard excess > 0 else { return }
        let doomed = Set(explicit.sorted { $0.lastUpdated < $1.lastUpdated }.prefix(excess).map(\.key))
        removeSessions { doomed.contains($0.key) }
    }

    /// Explicit sessions have no process-exit signal of their own. A dead pid,
    /// a finished turn, or a reporter that went silent must not pin the island.
    /// Managed sessions belong to their plugin, which ends them itself.
    private func prune() {
        let now = Date()
        removeSessions { session in
            guard session.source != .managed else { return false }
            let dead = session.pid.flatMap { pid_t(exactly: $0) }.map { !ActivityFocus.isProcessAlive($0) } ?? false
            let idle = now.timeIntervalSince(session.lastUpdated)
            return dead
                || (session.state == .completed && idle > Self.completedSessionLimit)
                || idle > NotchConfiguration.activityInactivityTimeout
        }
        recomputeActive()
    }

    private func recomputeActive() {
        activeSession = ActivityRules.active(ActivityRules.visible(Array(sessions.values), now: Date()))
    }

    // MARK: - Alert

    func triggerAlert(_ alert: ActivityAlert, autoDismissAfter seconds: TimeInterval? = nil) {
        currentAlert = alert
        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
            isShowingAlert = true
        }
        dismissTimer?.invalidate()
        if let seconds {
            dismissTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.dismissAlert() }
            }
        }
    }

    func dismissAlert() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        withAnimation(.spring(response: 0.25, dampingFraction: 0.88)) {
            isShowingAlert = false
        }
    }

    func focusActiveSession() {
        guard let session = activeSession else { return }
        dismissAlert()
        ActivityFocus.focus(pid: session.pid)
    }
}
```

- [ ] **Step 6: Build**

Run the Debug build. Expected `** BUILD SUCCEEDED **`. If `ActivityFocus` fails on a moved member referencing `DarwinProcessHelper`, replace that reference with `ActivityFocus`.

- [ ] **Step 7: Commit**

```bash
git add NotchNotch/Activity NotchNotch/Support/Log.swift NotchNotch/App/NotchConfiguration.swift
git commit -m "feat(activity): add agent-agnostic activity hub and focus"
```

---

### Task 5: Plugin host, managed processes and HTTP server

**Files:**
- Move: `NotchNotch/Agent/AgentHTTPServer.swift` → `NotchNotch/Plugins/PluginHTTPServer.swift`
- Modify: `NotchNotch/Agent/AgentHarnessController.swift` (two renamed symbols only)
- Create: `NotchNotch/Plugins/ManagedPluginProcess.swift`
- Create: `NotchNotch/Plugins/PluginHost.swift`
- Test: `.temp/plugin-checks/host/` (fixture plugin)

**Interfaces:**
- Consumes: Tasks 1–4.
- Produces: `PluginHTTPServer.start(port:onData:onEvent:)`, `PluginListenerEvent { .ready, .failed }`, `PluginListenerStatus { .stopped, .starting, .ready, .failed }`, `PluginStatus { .running, .stopped, .crashed, .invalid(String), .external }`, `PluginRecord { id, directory, manifest?, status, stderrTail }`, `PluginHost.shared` with `@Published plugins`, `isHTTPEnabled`, `listenerStatus`; `directory: URL`, `reload()`, `isEnabled(_:) -> Bool`, `setEnabled(_:_:)`, `setHTTPEnabled(_:)`, `stopAll()`.

- [ ] **Step 1: Rename the HTTP server**

```bash
mkdir -p NotchNotch/Plugins
git mv NotchNotch/Agent/AgentHTTPServer.swift NotchNotch/Plugins/PluginHTTPServer.swift
```

In `PluginHTTPServer.swift`:
- Header comment: `PluginHTTPServer.swift` / `Lightweight, zero-dependency embedded HTTP server for plugin messages on 127.0.0.1:7823/event.`
- `enum AgentListenerEvent` → `enum PluginListenerEvent`; `final class AgentHTTPServer` → `final class PluginHTTPServer`; every `AgentListenerEvent` inside → `PluginListenerEvent`.
- Queue label → `"co.jianyuelab.NotchNotch.pluginServer"`.
- `NotchConfiguration.agentHTTPRequestTimeout` → `NotchConfiguration.pluginHTTPRequestTimeout`.
- `finishRequest` validates against the protocol, so a hook script sees its mistake as a 400:

```swift
    /// 200 only for a body the hub can use, so a hook script sees its mistake.
    private func finishRequest(connection: NWConnection, body: Data) {
        guard PluginMessageDecoder.decode(body) != nil else {
            sendResponse(connection: connection, statusCode: 400, reason: "Bad Request")
            return
        }
        onDataReceived?(Data(body))
        sendResponse(connection: connection, statusCode: 200, reason: "OK")
    }
```

Add after the event enum:

```swift
enum PluginListenerStatus: Equatable {
    case stopped
    case starting
    case ready
    case failed
}
```

In `AgentHarnessController.swift` (still alive until Task 6): `AgentHTTPServer()` → `PluginHTTPServer()`, delete its `enum AgentListenerStatus` (lines 193-198) and change `AgentListenerStatus` → `PluginListenerStatus`. In `SettingsView.swift` nothing references the enum by name.

- [ ] **Step 2: Build**

Run the Debug build. Expected `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Write `ManagedPluginProcess.swift`**

```swift
//
//  ManagedPluginProcess.swift
//  NotchNotch
//
//  One managed plugin child: launch, JSON-line stdout, stderr tail, stop.
//  All mutable state is confined to `queue`; callbacks run on it and must hop
//  to the main actor themselves.
//

import Foundation
import OSLog

nonisolated final class ManagedPluginProcess: @unchecked Sendable {

    static let stopGrace: TimeInterval = 2
    static let stderrTailLines = 20

    let pluginID: String
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let queue: DispatchQueue
    private var lines = JSONLineBuffer()
    private var stderrPending = ""
    private var stderrTail: [String] = []

    private let onMessage: @Sendable (PluginMessage) -> Void
    private let onStderr: @Sendable ([String]) -> Void
    private let onExit: @Sendable (Int32) -> Void

    init(
        pluginID: String,
        executable: URL,
        workingDirectory: URL,
        onMessage: @escaping @Sendable (PluginMessage) -> Void,
        onStderr: @escaping @Sendable ([String]) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) {
        self.pluginID = pluginID
        self.queue = DispatchQueue(label: "co.jianyuelab.NotchNotch.plugin.\(pluginID)", qos: .utility)
        self.onMessage = onMessage
        self.onStderr = onStderr
        self.onExit = onExit
        process.executableURL = executable
        process.currentDirectoryURL = workingDirectory
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    /// `initialLines` (hello, config) are written before any output is read.
    func start(initialLines: [Data]) throws {
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            self?.queue.async { self?.consumeStdout(chunk) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            self?.queue.async { self?.consumeStderr(chunk) }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            self?.queue.async {
                guard let self else { return }
                self.stdoutPipe.fileHandleForReading.readabilityHandler = nil
                self.stderrPipe.fileHandleForReading.readabilityHandler = nil
                self.onExit(status)
            }
        }
        try process.run()
        for line in initialLines { send(line) }
    }

    func send(_ line: Data) {
        queue.async { [self] in
            guard process.isRunning else { return }
            // A dead plugin's pipe fails the write with EPIPE; SIGPIPE is ignored
            // process-wide in AppDelegate, so this cannot take the app down.
            try? stdinPipe.fileHandleForWriting.write(contentsOf: line + Data("\n".utf8))
        }
    }

    /// Closing stdin is the polite request; SIGTERM, then SIGKILL after the grace period.
    func stop() {
        queue.async { [self] in
            try? stdinPipe.fileHandleForWriting.close()
            guard process.isRunning else { return }
            process.terminate()
            let pid = process.processIdentifier
            queue.asyncAfter(deadline: .now() + Self.stopGrace) { [self] in
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
    }

    private func consumeStdout(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        for line in lines.append(chunk) {
            // The pipe names the plugin; an envelope `plugin` field is ignored here.
            if let envelope = PluginMessageDecoder.decode(line) {
                onMessage(envelope.message)
            } else {
                Log.plugins.error("plugin \(self.pluginID, privacy: .public) wrote an invalid message")
            }
        }
    }

    private func consumeStderr(_ chunk: Data) {
        guard !chunk.isEmpty, let text = String(data: chunk, encoding: .utf8) else { return }
        stderrPending += text
        var parts = stderrPending.components(separatedBy: "\n")
        stderrPending = parts.removeLast()
        guard !parts.isEmpty else { return }
        stderrTail = Array((stderrTail + parts).suffix(Self.stderrTailLines))
        onStderr(stderrTail)
    }
}
```

`process.terminate()` and `kill` need `import Foundation` only (`kill`/`SIGKILL` come through Foundation's Darwin re-export).

- [ ] **Step 4: Write `PluginHost.swift`**

```swift
//
//  PluginHost.swift
//  NotchNotch
//
//  Discovers plugins, owns their enablement, launches managed ones and routes
//  every plugin message (stdio or HTTP) into ActivityHub. Self-starting
//  singleton like the other controllers: touching `.shared` starts it.
//

import Combine
import Foundation
import OSLog

nonisolated enum PluginStatus: Equatable, Sendable {
    case running
    case stopped
    case crashed
    case invalid(String)
    case external
}

struct PluginRecord: Identifiable, Equatable {
    let id: String
    let directory: URL
    let manifest: PluginManifest?
    var status: PluginStatus
    var stderrTail: [String] = []
}

@MainActor
final class PluginHost: ObservableObject {

    static let shared = PluginHost()
    static let httpSourceID = "http"
    static let httpPort: UInt16 = 7823

    @Published private(set) var plugins: [PluginRecord] = []
    @Published private(set) var isHTTPEnabled: Bool
    @Published private(set) var listenerStatus: PluginListenerStatus = .stopped

    let directory: URL
    private let defaults = UserDefaults.standard
    private let hub = ActivityHub.shared
    private let httpServer = PluginHTTPServer()
    private var processes: [String: ManagedPluginProcess] = [:]
    private var policies: [String: RestartPolicy] = [:]
    private var restartTasks: [String: Task<Void, Never>] = [:]

    private init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchNotch/Plugins", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        isHTTPEnabled = true
        reload()
        PluginPreferences.migrate(defaults: defaults, installedPluginIDs: Set(plugins.compactMap { $0.manifest?.id }))
        isHTTPEnabled = PluginPreferences.isHTTPEnabled(in: defaults)
        if isHTTPEnabled { startHTTP() }
        for record in plugins where record.manifest?.kind == .managed && isEnabled(record.id) {
            launch(record.id)
        }
    }

    // MARK: - Discovery

    /// Rescans the directory. Symlinked plugin directories (nix store paths)
    /// are followed. Running processes of plugins that disappeared are stopped.
    func reload() {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let previous = Dictionary(plugins.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var records: [PluginRecord] = []
        var seen = Set<String>()

        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let resolved = entry.resolvingSymlinksInPath()
            guard (try? resolved.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            switch PluginManifest.load(from: resolved.appendingPathComponent("manifest.json")) {
            case .success(let manifest) where !seen.contains(manifest.id):
                seen.insert(manifest.id)
                var record = PluginRecord(id: manifest.id, directory: resolved, manifest: manifest, status: .stopped)
                if manifest.kind == .external {
                    record.status = .external
                } else if processes[manifest.id] != nil {
                    record.status = .running
                } else if previous[manifest.id]?.status == .crashed {
                    record.status = .crashed
                }
                record.stderrTail = previous[manifest.id]?.stderrTail ?? []
                records.append(record)
            case .success(let manifest):
                records.append(PluginRecord(id: entry.lastPathComponent, directory: resolved, manifest: nil,
                                            status: .invalid(PluginManifestError.duplicateID(manifest.id).description)))
            case .failure(let error):
                records.append(PluginRecord(id: entry.lastPathComponent, directory: resolved, manifest: nil,
                                            status: .invalid(error.description)))
            }
        }

        for id in Array(processes.keys) where !records.contains(where: { $0.id == id && $0.manifest?.kind == .managed }) {
            stopProcess(id)
        }
        for id in previous.keys where previous[id]?.manifest?.kind == .external && !seen.contains(id) {
            hub.removeSessions(of: id)
        }
        plugins = records
    }

    // MARK: - Enablement

    func isEnabled(_ id: String) -> Bool {
        PluginPreferences.isEnabled(id, in: defaults)
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        defaults.set(enabled, forKey: PluginPreferences.enabledKey(id))
        objectWillChange.send()
        guard let manifest = plugins.first(where: { $0.id == id })?.manifest else { return }
        switch manifest.kind {
        case .external:
            if !enabled { hub.removeSessions(of: id) }
        case .managed:
            if enabled {
                policies[id] = RestartPolicy()
                update(id) { $0.status = .stopped }
                launch(id)
            } else {
                stopProcess(id)
                update(id) { $0.status = .stopped }
            }
        }
    }

    func setHTTPEnabled(_ enabled: Bool) {
        isHTTPEnabled = enabled
        defaults.set(enabled, forKey: PluginPreferences.httpEnabledKey)
        if enabled {
            startHTTP()
        } else {
            httpServer.stop()
            listenerStatus = .stopped
            hub.removeSessions(from: [.external, .http])
        }
    }

    func stopAll() {
        for id in Array(processes.keys) { stopProcess(id) }
        httpServer.stop()
    }

    // MARK: - Managed processes

    private func launch(_ id: String) {
        guard processes[id] == nil,
              let record = plugins.first(where: { $0.id == id }),
              let manifest = record.manifest, manifest.kind == .managed,
              let executable = manifest.executable else { return }

        let process = ManagedPluginProcess(
            pluginID: id,
            executable: record.directory.appendingPathComponent(executable),
            workingDirectory: record.directory,
            onMessage: { [weak self] message in
                Task { @MainActor in self?.hub.apply(message, pluginID: id, source: .managed) }
            },
            onStderr: { [weak self] tail in
                Task { @MainActor in self?.update(id) { $0.stderrTail = tail } }
            },
            onExit: { [weak self] status in
                Task { @MainActor in self?.processExited(id, status: status) }
            }
        )
        do {
            try process.start(initialLines: [helloLine(), configLine()])
            processes[id] = process
            update(id) { $0.status = .running }
            Log.plugins.notice("plugin \(id, privacy: .public) started")
        } catch {
            update(id) { $0.status = .crashed; $0.stderrTail = [error.localizedDescription] }
            Log.plugins.error("plugin \(id, privacy: .public) failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func processExited(_ id: String, status: Int32) {
        // Absent means stopProcess already took it out: an intended stop, not a crash.
        guard processes.removeValue(forKey: id) != nil else { return }
        hub.removeSessions(of: id)
        var policy = policies[id] ?? RestartPolicy()
        let decision = policy.recordExit(at: Date())
        policies[id] = policy
        Log.plugins.error("plugin \(id, privacy: .public) exited with \(status)")

        switch decision {
        case .crashed:
            update(id) { $0.status = .crashed }
        case .restart(let delay):
            update(id) { $0.status = .stopped }
            restartTasks[id] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.restartTasks[id] = nil
                if self.isEnabled(id) { self.launch(id) }
            }
        }
    }

    private func stopProcess(_ id: String) {
        restartTasks.removeValue(forKey: id)?.cancel()
        guard let process = processes.removeValue(forKey: id) else { return }
        process.stop()
        hub.removeSessions(of: id)
    }

    private func helloLine() -> Data {
        let locale = LocalizationManager.shared.isChinese ? "zh-Hans" : "en"
        return (try? JSONSerialization.data(withJSONObject: [
            "type": "hello", "apiVersion": PluginManifest.currentAPIVersion, "locale": locale,
        ], options: [.sortedKeys])) ?? Data()
    }

    /// No plugin settings UI exists yet; plugins fall back to their defaults.
    private func configLine() -> Data {
        (try? JSONSerialization.data(withJSONObject: ["type": "config", "values": [String: Any]()], options: [.sortedKeys])) ?? Data()
    }

    private func update(_ id: String, _ change: (inout PluginRecord) -> Void) {
        guard let index = plugins.firstIndex(where: { $0.id == id }) else { return }
        change(&plugins[index])
    }

    // MARK: - HTTP

    /// Safe to call while already running: a bound listener keeps `.ready`.
    private func startHTTP() {
        if listenerStatus != .ready { listenerStatus = .starting }
        httpServer.start(
            port: Self.httpPort,
            onData: { [weak self] data in
                guard let envelope = PluginMessageDecoder.decode(data) else { return }
                Task { @MainActor in self?.receiveHTTP(envelope) }
            },
            onEvent: { [weak self] event in
                Task { @MainActor in
                    guard let self, self.isHTTPEnabled else { return }
                    self.listenerStatus = event == .ready ? .ready : .failed
                }
            }
        )
    }

    /// A body without `plugin` is the built-in HTTP source. A named plugin must
    /// be a registered, enabled external plugin, or the message is dropped.
    private func receiveHTTP(_ envelope: PluginEnvelope) {
        guard isHTTPEnabled else { return }
        guard let id = envelope.plugin else {
            hub.apply(envelope.message, pluginID: Self.httpSourceID, source: .http)
            return
        }
        guard plugins.first(where: { $0.id == id })?.manifest?.kind == .external, isEnabled(id) else {
            Log.plugins.notice("dropped HTTP message from unregistered or disabled plugin \(id, privacy: .public)")
            return
        }
        hub.apply(envelope.message, pluginID: id, source: .external)
    }
}
```

`PluginListenerEvent` must be `Equatable` for `event == .ready`; add `: Sendable, Equatable` to its declaration in `PluginHTTPServer.swift`.

- [ ] **Step 5: Build**

Run the Debug build. Expected `** BUILD SUCCEEDED **`. `PluginHost` is still unreferenced, so nothing changes at runtime.

- [ ] **Step 6: Commit**

```bash
git add NotchNotch/Plugins NotchNotch/Agent/AgentHarnessController.swift
git commit -m "feat(plugins): add plugin host, managed processes and HTTP routing"
```

---

### Task 6: Cut over the app to plugins

**Files:**
- Modify: `NotchNotch/App/AppDelegate.swift:12-30`
- Modify: `NotchNotch/Notch/NotchWindowController.swift:115,138,162,253`
- Modify: `NotchNotch/Views/NotchPanelView.swift` (agent references)
- Modify: `NotchNotch/Views/SettingsView.swift` (tab enum, `agentSection` lines 1018–1488, `agentController`, `showCopiedHookAlert`)
- Create: `NotchNotch/Views/PluginsSettingsSection.swift`
- Modify: `NotchNotch/Localization/L10n.swift`
- Modify: `NotchNotch/App/NotchConfiguration.swift:135-142` (delete `agent*`)
- Delete: `NotchNotch/Agent/` (`AgentHarnessController.swift`, `AgentModels.swift`, `AgentProcessMatcher.swift`, `OmpSession.swift`)

**Interfaces:**
- Consumes: `ActivityHub`, `ActivityAlert`, `ActivityState` presentation, `PluginHost`, `PluginRecord`, `PluginStatus`.
- Produces: `SettingsTab.plugins`, `PluginsSettingsSection`, L10n keys listed in Step 6.

- [ ] **Step 1: Start the plugin host at launch and stop it at quit**

In `AppDelegate.applicationDidFinishLaunching`, after the existing setup lines:

```swift
        // Writing to a plugin that has exited must fail with EPIPE, not kill the app.
        signal(SIGPIPE, SIG_IGN)
        // Starts the HTTP listener and enabled plugins.
        _ = PluginHost.shared
```

In `applicationWillTerminate`:

```swift
    func applicationWillTerminate(_ notification: Notification) {
        PluginHost.shared.stopAll()
        notchController?.stop()
    }
```

- [ ] **Step 2: Point the window controller at ActivityHub**

`NotchWindowController.swift`:
- line 115: `let isAgentActive = (ActivityHub.shared.activeSession?.state == .working || ActivityHub.shared.activeSession?.state.isWaiting == true)`
- line 138: `ActivityHub.shared.$activeSession,`
- line 162: `ActivityHub.shared.$isShowingAlert`
- line 253: `ActivityHub.shared.isShowingAlert || schedule.isShowingAlert`

- [ ] **Step 3: Point the panel at ActivityHub**

`NotchPanelView.swift`:
- line 37: `@ObservedObject private var activity = ActivityHub.shared`
- Replace every `agentController.` with `activity.` (isShowingAlert, currentAlert, isWaitingUser, isWaitingSubagent, isWorking).
- `AgentState.waitingUser.shortTag` → `ActivityState.waitingUser.shortTag`; same for `.waitingSubagent`.
- `private func agentAlertContent(_ alert: AgentAlert)` → `private func agentAlertContent(_ alert: ActivityAlert)`; inside it `alert.agent` → `alert.label` (two places); `agentController.focusActiveAgent()` → `activity.focusActiveSession()` (two places).

- [ ] **Step 4: Write `PluginsSettingsSection.swift`**

```swift
//
//  PluginsSettingsSection.swift
//  NotchNotch
//
//  Settings → Plugins: the HTTP listener and one row per discovered plugin.
//

import AppKit
import SwiftUI

struct PluginsSettingsSection: View {
    @ObservedObject private var host = PluginHost.shared
    @ObservedObject private var activity = ActivityHub.shared
    @ObservedObject private var loc = LocalizationManager.shared

    var body: some View {
        VStack(spacing: 14) {
            httpCard
            if host.plugins.isEmpty {
                Text(L10n.tr(.settingsPluginsEmpty))
                    .font(.system(size: 11.5))
                    .foregroundStyle(JYLTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .jylCard()
            } else {
                ForEach(host.plugins) { record in
                    row(record)
                }
            }
            actions
        }
    }

    private var httpCard: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr(.settingsPluginsHTTPTitle))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(JYLTheme.textPrimary)
                Text(L10n.tr(.settingsPluginsHTTPDesc))
                    .font(.system(size: 11))
                    .foregroundStyle(JYLTheme.textSecondary)
                Text(listenerText)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(host.listenerStatus == .failed ? JYLTheme.danger : JYLTheme.textMuted)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { host.isHTTPEnabled }, set: { host.setHTTPEnabled($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(14)
        .jylCard()
    }

    private var listenerText: String {
        switch host.listenerStatus {
        case .ready: return L10n.tr(.agentListenerReady)
        case .starting: return L10n.tr(.agentListenerStarting)
        case .failed: return L10n.tr(.agentListenerFailed)
        case .stopped: return L10n.tr(.commonDisabled)
        }
    }

    private func row(_ record: PluginRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(record.manifest?.displayName(isChinese: loc.isChinese) ?? record.id)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(JYLTheme.textPrimary)
                if let version = record.manifest?.version {
                    Text(version)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(JYLTheme.textMuted)
                }
                Text(statusText(record.status))
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(statusColor(record.status))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(statusColor(record.status).opacity(0.15)))
                Spacer()
                if record.manifest != nil {
                    Toggle("", isOn: Binding(get: { host.isEnabled(record.id) }, set: { host.setEnabled(record.id, $0) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }
            Text(record.id)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(JYLTheme.textMuted)
            if case .invalid(let reason) = record.status {
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundStyle(JYLTheme.danger)
            }
            if !record.stderrTail.isEmpty {
                Text(record.stderrTail.joined(separator: "\n"))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(JYLTheme.textSecondary)
                    .lineLimit(20)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .jylCard()
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button(L10n.tr(.settingsPluginsOpenFolder)) {
                NSWorkspace.shared.open(host.directory)
            }
            Button(L10n.tr(.settingsPluginsReload)) {
                host.reload()
            }
            Spacer()
            Button(L10n.tr(.settingsPluginsTestAlert)) {
                activity.triggerAlert(
                    ActivityAlert(sessionKey: "test/alert", label: "NotchNotch", state: .waitingUser,
                                  title: loc.isChinese ? "需要确认权限" : "Permission Required", pid: nil, timestamp: Date()),
                    autoDismissAfter: 5
                )
            }
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
    }

    private func statusText(_ status: PluginStatus) -> String {
        switch status {
        case .running: return L10n.tr(.pluginStatusRunning)
        case .stopped: return L10n.tr(.pluginStatusStopped)
        case .crashed: return L10n.tr(.pluginStatusCrashed)
        case .invalid: return L10n.tr(.pluginStatusInvalid)
        case .external: return L10n.tr(.pluginStatusExternal)
        }
    }

    private func statusColor(_ status: PluginStatus) -> Color {
        switch status {
        case .running: return JYLTheme.success
        case .stopped, .external: return JYLTheme.textMuted
        case .crashed, .invalid: return JYLTheme.danger
        }
    }
}
```

If `JYLTheme.danger` does not exist, use the red token `JYLTheme` defines (`grep -n 'static let' NotchNotch/Support/JYLTheme.swift`).

- [ ] **Step 5: Swap the Settings tab**

`SettingsView.swift`:
- `case agent = "agent"` → `case plugins = "plugins"`; title `case .plugins: return L10n.tr(.settingsTabPlugins)`; icon `case .plugins: return "puzzlepiece.extension.fill"`.
- In the tab switch: `case .plugins: PluginsSettingsSection()`.
- Delete `private var agentSection: some View { … }` (lines 1018–1488 at commit `caf42ac`; it ends just before `private var clipboardSection`).
- Delete `@ObservedObject private var agentController = AgentHarnessController.shared` and the `@State` property `showCopiedHookAlert`.

- [ ] **Step 6: Update L10n**

In `L10n.swift`, in the `L10nKey` enum:
- Replace `case settingsTabAgent` with `case settingsTabPlugins`.
- Delete `case agentWaitingUser`, `agentWaitingSubagent`, `agentWorking`, `agentJumpToTerminal`, `agentAlertDismiss` (no remaining references), and the whole `// MARK: - Settings Agent` group (8 cases).
- Add a group:

```swift
    // MARK: - Settings Plugins
    case settingsPluginsHTTPTitle
    case settingsPluginsHTTPDesc
    case settingsPluginsEmpty
    case settingsPluginsOpenFolder
    case settingsPluginsReload
    case settingsPluginsTestAlert
    case pluginStatusRunning
    case pluginStatusStopped
    case pluginStatusCrashed
    case pluginStatusInvalid
    case pluginStatusExternal
```

Chinese table: delete the five removed `agent*` entries and the `// Settings Agent` block; `.settingsTabAgent: "AI Agent"` → `.settingsTabPlugins: "插件"`; add:

```swift
        // Settings Plugins
        .settingsPluginsHTTPTitle: "本地事件接口",
        .settingsPluginsHTTPDesc: "监听 127.0.0.1:7823/event，接收外部插件和 Hook 脚本推送的会话事件",
        .settingsPluginsEmpty: "尚未安装插件。把插件文件夹放进插件目录后点击刷新。",
        .settingsPluginsOpenFolder: "打开插件目录",
        .settingsPluginsReload: "刷新",
        .settingsPluginsTestAlert: "测试灵动岛提醒",
        .pluginStatusRunning: "运行中",
        .pluginStatusStopped: "已停止",
        .pluginStatusCrashed: "已崩溃",
        .pluginStatusInvalid: "无效",
        .pluginStatusExternal: "外部",
```

English table: the same deletions; `.settingsTabAgent: "AI Agent"` → `.settingsTabPlugins: "Plugins"`; add:

```swift
        // Settings Plugins
        .settingsPluginsHTTPTitle: "Local Event API",
        .settingsPluginsHTTPDesc: "Listens on 127.0.0.1:7823/event for session events from external plugins and hook scripts",
        .settingsPluginsEmpty: "No plugins installed. Put a plugin folder in the plugins directory, then refresh.",
        .settingsPluginsOpenFolder: "Open Plugins Folder",
        .settingsPluginsReload: "Refresh",
        .settingsPluginsTestAlert: "Test Notch Alert",
        .pluginStatusRunning: "Running",
        .pluginStatusStopped: "Stopped",
        .pluginStatusCrashed: "Crashed",
        .pluginStatusInvalid: "Invalid",
        .pluginStatusExternal: "External",
```

- [ ] **Step 7: Delete the old agent code and constants**

```bash
git rm NotchNotch/Agent/AgentHarnessController.swift NotchNotch/Agent/AgentModels.swift NotchNotch/Agent/AgentProcessMatcher.swift NotchNotch/Agent/OmpSession.swift
```

In `NotchConfiguration.swift`, delete `agentHookInactivityTimeout`, `agentMaxHookSessions`, `agentHTTPRequestTimeout` and their comments.

- [ ] **Step 8: Build and check key parity**

Run the Debug build. Expected `** BUILD SUCCEEDED **`. Fix any leftover `AgentHarnessController`/`AgentState`/`AgentAlert` reference the compiler reports by applying the same renames.

Run: `grep -rn 'AgentHarnessController\|AgentState\|AgentAlert\|DarwinProcessHelper\|OmpSession' NotchNotch`
Expected: no output.

Parity check (both tables have the same keys):

```bash
swift -e 'import Foundation; let s = try! String(contentsOfFile: "NotchNotch/Localization/L10n.swift", encoding: .utf8); let keys = s.matches(of: /\n        \.(\w+):/).map { String($0.1) }; let half = keys.count / 2; print(keys.count % 2 == 0 && Set(keys.prefix(half)) == Set(keys.suffix(half)) ? "PARITY OK" : "PARITY BROKEN")'
```

Expected: `PARITY OK`.

- [ ] **Step 9: End-to-end with the legacy HTTP path**

```bash
pkill -f NotchNotch.app; build/DerivedData/Build/Products/Debug/NotchNotch.app/Contents/MacOS/NotchNotch > .temp/app_stdout.log 2>&1 &
sleep 3
curl -s -X POST localhost:7823/event -H 'Content-Type: application/json' -d '{"state":"working","agent":"claude","session_id":"plan-test"}'
curl -s -X POST localhost:7823/event -H 'Content-Type: application/json' -d '{"state":"completed","agent":"claude","session_id":"plan-test","title":"Legacy title"}'
sleep 0.5; screencapture -x -R 550,0,700,60 .temp/plugin-checks/legacy-alert.png
curl -s -o /dev/null -w '%{http_code}\n' -X POST localhost:7823/event -d '{"type":"bogus"}'
```

Expected: both POSTs print `{"status":"ok"}`; the screenshot shows the alert bar with "Legacy title" above "claude" and "Completed"; the bogus body prints `400`. Open Settings (`co.jianyuelab.NotchNotch.selectTab` with object `"settings"`) and confirm the Plugins tab shows the HTTP card as running and "No plugins installed".

- [ ] **Step 10: Commit**

```bash
git add -A NotchNotch
git commit -m "refactor(activity): route all sessions through plugins; remove built-in agent detection"
```

---

### Task 7: Agent plugin

**Files:**
- Create: `plugins/agents/Package.swift`
- Create: `plugins/agents/manifest.json`
- Create: `plugins/agents/build.sh`
- Create: `plugins/agents/Sources/agents/AgentProcessMatcher.swift` (from git history, omp rule removed)
- Create: `plugins/agents/Sources/agents/ProcessSnapshot.swift`
- Create: `plugins/agents/Sources/agents/AgentScanner.swift`
- Create: `plugins/agents/Sources/agents/Wire.swift`
- Create: `plugins/agents/Sources/agents/main.swift`
- Modify: `.gitignore` (add `plugins/agents/.build/`)
- Test: `.temp/plugin-checks/agents/main.swift`

**Interfaces:**
- Produces on stdout: `session.update` (`id` = `<lowercased-name>-<pid>`, `state` working/waitingUser, `label` = agent name, `pid`, `cwd` on first update, `alert` true on working→waitingUser) and `session.end` (`alert: true`).
- Reads stdin: `hello`, `config` (`values.pollInterval` ≥ 1). EOF → exit 0.

- [ ] **Step 1: Restore the matcher from history**

```bash
mkdir -p plugins/agents/Sources/agents
git show "$(git log -1 --format=%H --diff-filter=D -- NotchNotch/Agent/AgentProcessMatcher.swift)^:NotchNotch/Agent/AgentProcessMatcher.swift" > plugins/agents/Sources/agents/AgentProcessMatcher.swift
```

(The parent of the commit that deleted the file, i.e. the last version before the cutover.)

Edit the restored file:
- Header: `//  AgentProcessMatcher.swift` / `//  NotchNotch agent plugin` and keep the existing description.
- Remove the omp case and its comments:

```swift
            case "grok": agent = "Grok"
            case "codex": agent = "Codex"
            default: continue
```

- Change the rule comment back to `// 1–2. Grok / Codex: executable name only, …` and the doc comment to `Grok and Codex come first …`; renumber the following rules 3–6.
- Replace `comm.contains("notchnotch")` in `isScanNoise` with a check that also skips this plugin: `return comm.contains("notchnotch") || comm == "agents"`.

- [ ] **Step 2: Write the failing test**

`.temp/plugin-checks/agents/main.swift`:

```swift
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "PASS" : "FAIL", what); if !ok { failures += 1 } }

let psOutput = """
  PID  PPID  %CPU STAT TTY      COMM             ARGS
  100     1   0.0 Ss   ttys001  /bin/zsh         -zsh
  200   100   5.0 S+   ttys001  claude           claude
  300   100   0.0 S+   ttys002  omp              omp --resume x
  400     1   0.0 S    ??       codex            codex exec run
"""
let entries = ProcessSnapshot.parse(psOutput)
check(entries.count == 4, "four rows parsed")
check(entries[1].pid == 200 && entries[1].cpu == 5.0 && entries[1].tty == "ttys001", "row fields")

var scanner = AgentScanner()
let first = scanner.step(entries: entries, cwd: { _ in "/w" })
check(first == [.update(id: "claude-code-200", state: .working, label: "Claude Code", pid: 200, cwd: "/w", alert: false)], "only claude matched (omp unknown, codex without tty skipped)")

func quiet(_ cpu: Double) -> [ProcessRawEntry] {
    [ProcessRawEntry(pid: 200, ppid: 100, cpu: cpu, state: "S+", tty: "ttys001", comm: "claude", args: "claude")]
}
check(scanner.step(entries: quiet(0), cwd: { _ in nil }).isEmpty, "1st quiet poll keeps working")
check(scanner.step(entries: quiet(0), cwd: { _ in nil }).isEmpty, "2nd quiet poll keeps working")
check(scanner.step(entries: quiet(0), cwd: { _ in nil }) == [.update(id: "claude-code-200", state: .waitingUser, label: "Claude Code", pid: 200, cwd: nil, alert: true)], "3rd quiet poll -> waitingUser with alert")
check(scanner.step(entries: quiet(9), cwd: { _ in nil }) == [.update(id: "claude-code-200", state: .working, label: "Claude Code", pid: 200, cwd: nil, alert: false)], "busy again -> working, no alert")
check(scanner.step(entries: [], cwd: { _ in nil }) == [.end(id: "claude-code-200", alert: true)], "exit -> end with alert")

let line = String(data: Wire.line(.update(id: "a-1", state: .working, label: "A", pid: 1234, cwd: nil, alert: false)), encoding: .utf8)!
check(line == #"{"alert":false,"id":"a-1","label":"A","pid":1234,"state":"working","type":"session.update"}"# + "\n", "update wire format")
check(String(data: Wire.line(.end(id: "a-1", alert: true)), encoding: .utf8)! == #"{"alert":true,"id":"a-1","type":"session.end"}"# + "\n", "end wire format")
check(Wire.pollInterval(fromConfigLine: #"{"type":"config","values":{"pollInterval":2}}"#) == 2, "config interval")
check(Wire.pollInterval(fromConfigLine: #"{"type":"config","values":{"pollInterval":0.1}}"#) == nil, "interval below 1 ignored")
check(Wire.pollInterval(fromConfigLine: #"{"type":"hello","apiVersion":1}"#) == nil, "hello ignored")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
```

- [ ] **Step 3: Run test to verify it fails**

Run: `mkdir -p .temp/plugin-checks/agents && swiftc plugins/agents/Sources/agents/AgentProcessMatcher.swift plugins/agents/Sources/agents/ProcessSnapshot.swift plugins/agents/Sources/agents/AgentScanner.swift plugins/agents/Sources/agents/Wire.swift .temp/plugin-checks/agents/main.swift -o .temp/plugin-checks/agents/run`
Expected: FAIL, no such file `ProcessSnapshot.swift`.

- [ ] **Step 4: Write `ProcessSnapshot.swift`**

```swift
//
//  ProcessSnapshot.swift
//  NotchNotch agent plugin
//
//  `ps` output → rows, and a process's cwd from the kernel.
//

import Darwin.libproc
import Foundation

enum ProcessSnapshot {

    /// `%cpu` follows LC_NUMERIC. `Double` only accepts a dot, so a comma locale drops every row.
    static func run() -> String? {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-eo", "pid,ppid,%cpu,state,tty,comm,args"]
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        environment["LANG"] = "C"
        environment["LC_NUMERIC"] = "C"
        ps.environment = environment
        let pipe = Pipe()
        ps.standardOutput = pipe
        do {
            try ps.run()
        } catch {
            FileHandle.standardError.write(Data("ps failed: \(error.localizedDescription)\n".utf8))
            return nil
        }
        // Read before waitUntilExit, or a full 64 KB pipe buffer deadlocks both sides.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// The first six columns are single tokens; everything after is `args`,
    /// which may contain spaces.
    static func parse(_ output: String) -> [ProcessRawEntry] {
        var entries: [ProcessRawEntry] = []
        for line in output.components(separatedBy: .newlines).dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            var parts: [String] = []
            var token = ""
            var index = trimmed.startIndex
            while index < trimmed.endIndex && parts.count < 6 {
                let char = trimmed[index]
                if char.isWhitespace {
                    if !token.isEmpty { parts.append(token); token = "" }
                } else {
                    token.append(char)
                }
                index = trimmed.index(after: index)
            }
            if parts.count < 6 && !token.isEmpty { parts.append(token) }
            guard parts.count >= 6,
                  let pid = Int(parts[0]),
                  let ppid = Int(parts[1]),
                  let cpu = Double(parts[2].replacingOccurrences(of: ",", with: ".")) else { continue }
            let args = String(trimmed[index...]).trimmingCharacters(in: .whitespaces)
            entries.append(ProcessRawEntry(pid: pid, ppid: ppid, cpu: cpu, state: parts[3], tty: parts[4],
                                           comm: parts[5], args: args.isEmpty ? parts[5] : args))
        }
        return entries
    }

    /// Current working directory via proc_pidinfo, without shelling out.
    static func cwd(of pid: Int) -> String? {
        guard let pid32 = pid_t(exactly: pid) else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid32, PROC_PIDVNODEPATHINFO, 0, &info, size) > 0 else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { cString in
                let path = String(cString: cString).trimmingCharacters(in: .whitespacesAndNewlines)
                return path.isEmpty ? nil : path
            }
        }
    }
}
```

- [ ] **Step 5: Write `AgentScanner.swift`**

```swift
//
//  AgentScanner.swift
//  NotchNotch agent plugin
//
//  Turns successive ps snapshots into session messages. CPU is the only
//  signal, so "needs input" is a guess: one quiet poll is not enough.
//

import Foundation

enum WireState: String {
    case working
    case waitingUser
}

enum OutgoingMessage: Equatable {
    case update(id: String, state: WireState, label: String, pid: Int, cwd: String?, alert: Bool)
    case end(id: String, alert: Bool)
}

struct AgentScanner {
    static let quietPollsBeforeWaiting = 3
    static let busyCPU = 1.5

    private struct Tracked {
        var state: WireState
        var quietPolls: Int
    }

    private var tracked: [String: Tracked] = [:]

    /// Messages are emitted on change only; an unchanged agent is silent.
    mutating func step(entries: [ProcessRawEntry], cwd: (Int) -> String?) -> [OutgoingMessage] {
        var messages: [OutgoingMessage] = []
        var seen = Set<String>()

        for agent in AgentProcessMatcher.discover(entries) {
            let id = "\(agent.name.lowercased().replacingOccurrences(of: " ", with: "-"))-\(agent.pid)"
            seen.insert(id)
            let usage = AgentProcessMatcher.cpuUsage(of: agent, in: entries)
            var inferred: WireState = (usage.hasActiveTool || usage.total > Self.busyCPU) ? .working : .waitingUser

            guard var session = tracked[id] else {
                tracked[id] = Tracked(state: inferred, quietPolls: 0)
                messages.append(.update(id: id, state: inferred, label: agent.name, pid: agent.pid, cwd: cwd(agent.pid), alert: false))
                continue
            }
            if session.state == .working && inferred == .waitingUser {
                session.quietPolls += 1
                if session.quietPolls < Self.quietPollsBeforeWaiting { inferred = .working }
            } else if inferred == .working {
                session.quietPolls = 0
            }
            if session.state != inferred {
                let alert = session.state == .working && inferred == .waitingUser
                if alert { session.quietPolls = 0 }
                session.state = inferred
                messages.append(.update(id: id, state: inferred, label: agent.name, pid: agent.pid, cwd: nil, alert: alert))
            }
            tracked[id] = session
        }

        // Every tracked agent is working or waiting, so an exit always deserves an alert.
        for id in tracked.keys.sorted() where !seen.contains(id) {
            tracked.removeValue(forKey: id)
            messages.append(.end(id: id, alert: true))
        }
        return messages
    }
}
```

- [ ] **Step 6: Write `Wire.swift`**

```swift
//
//  Wire.swift
//  NotchNotch agent plugin
//
//  The plugin side of the NotchNotch plugin protocol (apiVersion 1).
//

import Foundation

enum Wire {
    static func line(_ message: OutgoingMessage) -> Data {
        var object: [String: Any]
        switch message {
        case let .update(id, state, label, pid, cwd, alert):
            object = ["type": "session.update", "id": id, "state": state.rawValue, "label": label, "pid": pid, "alert": alert]
            if let cwd { object["cwd"] = cwd }
        case let .end(id, alert):
            object = ["type": "session.end", "id": id, "alert": alert]
        }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return data + Data("\n".utf8)
    }

    static func pollInterval(fromConfigLine line: String) -> Double? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              object["type"] as? String == "config",
              let values = object["values"] as? [String: Any],
              let interval = values["pollInterval"] as? Double,
              interval >= 1 else { return nil }
        return interval
    }
}
```

- [ ] **Step 7: Run test to verify it passes**

Run: `swiftc plugins/agents/Sources/agents/AgentProcessMatcher.swift plugins/agents/Sources/agents/ProcessSnapshot.swift plugins/agents/Sources/agents/AgentScanner.swift plugins/agents/Sources/agents/Wire.swift .temp/plugin-checks/agents/main.swift -o .temp/plugin-checks/agents/run && .temp/plugin-checks/agents/run`
Expected: `ALL PASS`.

- [ ] **Step 8: Write `main.swift`, `Package.swift`, `manifest.json`, `build.sh`**

`plugins/agents/Sources/agents/main.swift`:

```swift
//
//  main.swift
//  NotchNotch agent plugin
//
//  Launched by NotchNotch. Writes session messages to stdout, reads hello and
//  config from stdin, and exits when stdin closes so it never outlives the app.
//

import Foundation

@MainActor
final class AgentPlugin {
    private var scanner = AgentScanner()
    private var timer: DispatchSourceTimer?
    private var interval: TimeInterval = 4

    func start() {
        schedule()
    }

    func applyConfig(pollInterval: Double?) {
        guard let pollInterval, pollInterval != interval else { return }
        interval = pollInterval
        schedule()
    }

    private func schedule() {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.resume()
        self.timer = timer
    }

    private func poll() {
        guard let output = ProcessSnapshot.run() else { return }
        let entries = ProcessSnapshot.parse(output)
        for message in scanner.step(entries: entries, cwd: ProcessSnapshot.cwd(of:)) {
            FileHandle.standardOutput.write(Wire.line(message))
        }
    }
}

let plugin = AgentPlugin()
plugin.start()

Thread.detachNewThread {
    while let line = readLine() {
        let interval = Wire.pollInterval(fromConfigLine: line)
        DispatchQueue.main.async {
            MainActor.assumeIsolated { plugin.applyConfig(pollInterval: interval) }
        }
    }
    exit(0)
}

dispatchMain()
```

`plugins/agents/Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotchNotchAgents",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "agents", path: "Sources/agents"),
    ]
)
```

`plugins/agents/manifest.json`:

```json
{
  "id": "co.jianyuelab.notchnotch.agents",
  "name": { "en": "Agent Detection", "zh-Hans": "Agent 识别" },
  "version": "27.2.0",
  "kind": "managed",
  "executable": "agents",
  "apiVersion": 1
}
```

`plugins/agents/build.sh` (mode 755):

```bash
#!/bin/bash
# Builds, signs and zips the agent plugin into build/plugins/agents/.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(plutil -extract version raw manifest.json)
ID=$(plutil -extract id raw manifest.json)
IDENTITY="${IDENTITY:-Developer ID Application: JIANYUELAB LTD (D26JNXU8V2)}"
OUT="../../build/plugins/agents"

swift build -c release --arch arm64
rm -rf "$OUT"
mkdir -p "$OUT/$ID"
cp .build/arm64-apple-macosx/release/agents manifest.json "$OUT/$ID/"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$OUT/$ID/agents"
(cd "$OUT" && ditto -c -k --keepParent "$ID" "NotchNotchAgents-$VERSION.zip")
echo "$OUT/NotchNotchAgents-$VERSION.zip"
```

Append to `.gitignore`:

```
plugins/agents/.build/
```

- [ ] **Step 9: Build and run the plugin standalone**

Run: `chmod +x plugins/agents/build.sh && plugins/agents/build.sh`
Expected: last line `../../build/plugins/agents/NotchNotchAgents-27.2.0.zip`.

Run: `(echo '{"type":"hello","apiVersion":1}'; sleep 5) | build/plugins/agents/co.jianyuelab.notchnotch.agents/agents`
Expected: one `session.update` line per running Claude Code/Codex/Grok/OpenCode/Aider/Antigravity session with a TTY, then exit after 5 s (stdin EOF).

- [ ] **Step 10: End-to-end through the app**

```bash
PLUGINS="$HOME/Library/Application Support/NotchNotch/Plugins"
mkdir -p "$PLUGINS" && rm -rf "$PLUGINS/co.jianyuelab.notchnotch.agents"
cp -R build/plugins/agents/co.jianyuelab.notchnotch.agents "$PLUGINS/"
pkill -f NotchNotch.app; build/DerivedData/Build/Products/Debug/NotchNotch.app/Contents/MacOS/NotchNotch > .temp/app_stdout.log 2>&1 &
sleep 6; pgrep -fl 'Plugins/co.jianyuelab.notchnotch.agents/agents'
/usr/bin/log show --last 10s --style compact --predicate 'subsystem == "co.jianyuelab.NotchNotch" AND category == "plugins"'
```

Expected: the plugin process is listed; the log shows `plugin co.jianyuelab.notchnotch.agents started` and `session co.jianyuelab.notchnotch.agents/claude-code-<pid> -> …` for each running agent.

Crash handling: run `pkill -f 'Plugins/co.jianyuelab.notchnotch.agents/agents'` five times, waiting for `pgrep` to show the restarted process between kills. Expected: after the fifth kill no process is restarted, and Settings → Plugins shows the agent plugin as Crashed. Toggle it off and on: it starts again.

- [ ] **Step 11: Commit**

```bash
git add plugins/agents .gitignore
git commit -m "feat(agents): move agent detection into a managed plugin"
```

---

### Task 8: omp plugin and docs

**Files:**
- Move: `scripts/omp/notchnotch.ts` → `plugins/omp/notchnotch.ts`
- Create: `plugins/omp/manifest.json`
- Modify: `README.md:35-40`, `CLAUDE.md` (Agent harness section, Commands, Verification)

**Interfaces:**
- Produces: HTTP `session.update` from `plugin: "co.jianyuelab.notchnotch.omp"`.

- [ ] **Step 1: Move and rewrite the extension**

```bash
mkdir -p plugins/omp && git mv scripts/omp/notchnotch.ts plugins/omp/notchnotch.ts
```

`plugins/omp/notchnotch.ts`:

```ts
// NotchNotch omp plugin: reports main-session turns to NotchNotch.
// Install: link this file into ~/.omp/agent/extensions/ and manifest.json's
// directory into ~/Library/Application Support/NotchNotch/Plugins/.
import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";

const ENDPOINT = "http://127.0.0.1:7823/event";
const PLUGIN_ID = "co.jianyuelab.notchnotch.omp";
const TIMEOUT_MS = 1_000;

function report(ctx: ExtensionContext, state: "working" | "completed"): void {
	// Subagent sessions (task tool, eval agent(), /tan clones) fire the same events.
	if (ctx.agent.kind !== "main") return;
	const body = {
		type: "session.update",
		plugin: PLUGIN_ID,
		id: ctx.sessionManager.getSessionId(),
		state,
		label: "omp",
		title: ctx.sessionManager.getSessionName() ?? "",
		cwd: ctx.cwd,
		pid: process.pid,
		alert: state === "completed",
	};
	// NotchNotch not running is normal; never surface it in the session.
	fetch(ENDPOINT, {
		method: "POST",
		headers: { "Content-Type": "application/json" },
		body: JSON.stringify(body),
		signal: AbortSignal.timeout(TIMEOUT_MS),
	}).catch(() => {});
}

export default function notchnotch(pi: ExtensionAPI) {
	pi.on("agent_start", (_event, ctx) => report(ctx, "working"));
	pi.on("agent_end", (_event, ctx) => report(ctx, "completed"));
}
```

`plugins/omp/manifest.json`:

```json
{
  "id": "co.jianyuelab.notchnotch.omp",
  "name": { "en": "omp", "zh-Hans": "omp" },
  "version": "27.2.0",
  "kind": "external",
  "apiVersion": 1
}
```

- [ ] **Step 2: End-to-end with a real omp turn**

```bash
PLUGINS="$HOME/Library/Application Support/NotchNotch/Plugins"
mkdir -p "$PLUGINS/co.jianyuelab.notchnotch.omp" && cp plugins/omp/manifest.json "$PLUGINS/co.jianyuelab.notchnotch.omp/"
mkdir -p .temp/plugin-checks/omp-ws && cd .temp/plugin-checks/omp-ws
omp -p -e "$OLDPWD/plugins/omp/notchnotch.ts" --session-dir "$PWD/../omp-sessions" "Reply with exactly: ok"
cd "$OLDPWD"
/usr/bin/log show --last 30s --style compact --predicate 'subsystem == "co.jianyuelab.NotchNotch" AND category == "plugins"' | grep notchnotch.omp
```

Expected (app relaunched after installing the manifest, or Refresh pressed in Settings): two lines `session co.jianyuelab.notchnotch.omp/<session id> -> working` then `-> completed`. With the omp manifest disabled in Settings, rerunning produces `dropped HTTP message from unregistered or disabled plugin co.jianyuelab.notchnotch.omp` and no session.

If `~/.omp/agent/extensions/notchnotch.ts` exists from nix-config, the `-e` flag loads it twice; run with `--no-extensions -e …` instead.

- [ ] **Step 3: Update docs**

`README.md`, replace the AI Agent bullet group (lines 35–40) with:

```markdown
- **Plugins**:
  - Agent Detection plugin: detects local CLI agents (**Claude Code**, **Antigravity**, **Codex**, **Grok**, **OpenCode**, **Aider**) by process scanning. Released as `NotchNotchAgents-<version>.zip`; unzip into `~/Library/Application Support/NotchNotch/Plugins/`.
  - omp plugin (`plugins/omp/`): exact omp turn ends with the conversation title. Link `notchnotch.ts` into `~/.omp/agent/extensions/` and the `plugins/omp` directory into the Plugins directory.
  - Local event API on `127.0.0.1:7823/event` for hook scripts and external plugins.
  - Clicking an alert focuses the hosting terminal (Ghostty, Zed, iTerm, Terminal, Warp, VS Code, tmux).
```

`CLAUDE.md`:
- Replace the whole `### Agent harness (Agent/)` section with:

```markdown
### Plugins (`Plugins/`, `Activity/`, `plugins/`)

The core has no agent-specific code. Spec: `docs/superpowers/specs/2026-11-10-process-plugins-design.md`.

- `PluginHost` scans `~/Library/Application Support/NotchNotch/Plugins/<id>/manifest.json` (symlinks
  followed), launches `managed` plugins and reads JSON lines from their stdout, restarts them with
  backoff (5 exits in 10 min = crashed), and routes HTTP bodies from `127.0.0.1:7823/event`.
- `ActivityHub` holds every session (`<plugin id>/<session id>`), picks the active one, dedups a
  managed session against an explicit report of the same pid (180 s), and shows alerts. Plugins set
  `alert`; legacy HTTP bodies (no `type`) alert on the old transitions.
- `ActivityFocus` turns a session pid into the hosting GUI app (tmux special case included).
- `plugins/agents/`: SwiftPM agent plugin. `plugins/agents/build.sh` builds, signs and zips it.
- `plugins/omp/`: omp extension + `external` manifest.
- Pure files (`PluginMessage`, `PluginManifest`, `PluginPreferences`, `RestartPolicy`,
  `ActivityState`, `ActivityRules`) compile in `.temp/` scripts.
```

- In the Commands section, add after the build commands:

```markdown
# Agent plugin: build, sign and zip into build/plugins/agents/
plugins/agents/build.sh
```

- In the Live activity section, keep the CombineLatest4 note; it now reads `ActivityHub.shared.$activeSession`.
- Replace `Categories in Support/Log.swift: …, media, location.` with the list including `plugins`.

- [ ] **Step 4: Commit**

```bash
git add plugins/omp README.md CLAUDE.md
git commit -m "feat(omp): ship the omp extension as an external NotchNotch plugin"
```

---

### Task 9: Release 27.2.0 and nix-config

**Files:**
- Modify: `NotchNotch.xcodeproj/project.pbxproj:263,299`
- Modify (nix-config): `flake.nix`, `flake.lock`, `home/jhl/common/optional/ai/omp.nix`

- [ ] **Step 1: Bump the version**

Set both `MARKETING_VERSION = 27.1.11;` lines to `MARKETING_VERSION = 27.2.0;`.

```bash
git add NotchNotch.xcodeproj/project.pbxproj
git commit -m "chore: bump MARKETING_VERSION to 27.2.0"
git tag -a v27.2.0 -m v27.2.0
git push org main && git push org v27.2.0
```

- [ ] **Step 2: Build, sign and zip both artifacts**

```bash
rm -rf .temp/rel && mkdir -p .temp/rel
xcodebuild -scheme NotchNotch -configuration Release -derivedDataPath .temp/rel/dd \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application: JIANYUELAB LTD (D26JNXU8V2)" \
  DEVELOPMENT_TEAM=D26JNXU8V2 PROVISIONING_PROFILE_SPECIFIER= OTHER_CODE_SIGN_FLAGS="--timestamp" build \
  2>&1 | grep -E 'error:|BUILD (SUCCEEDED|FAILED)'
codesign --verify --deep --strict .temp/rel/dd/Build/Products/Release/NotchNotch.app && echo verify-ok
(cd .temp/rel && ditto -c -k --keepParent dd/Build/Products/Release/NotchNotch.app NotchNotch-27.2.0.zip)
plugins/agents/build.sh
codesign --verify --strict build/plugins/agents/co.jianyuelab.notchnotch.agents/agents && echo plugin-verify-ok
```

Expected: `** BUILD SUCCEEDED **`, `verify-ok`, `plugin-verify-ok`.

- [ ] **Step 3: Publish the release**

```bash
gh release create v27.2.0 .temp/rel/NotchNotch-27.2.0.zip build/plugins/agents/NotchNotchAgents-27.2.0.zip \
  -R JianyueLab-Org/notch --title v27.2.0 --notes "### NotchNotch v27.2.0

- Agent detection and omp support are plugins. The app ships without them.
- \`NotchNotchAgents-27.2.0.zip\`: Agent Detection plugin. Unzip into \`~/Library/Application Support/NotchNotch/Plugins/\`.
- omp plugin: \`plugins/omp/\` in the repo.
- Settings → Plugins lists plugins, their status and the local event API.
- Existing hook scripts posting to \`127.0.0.1:7823/event\` keep working."
```

Update the Homebrew cask in `JianyueLab/homebrew-tap` (`Casks/notchnotch.rb`): `version "27.2.0"` and the `sha256` of `NotchNotch-27.2.0.zip` (`shasum -a 256 .temp/rel/NotchNotch-27.2.0.zip`), committed as `notchnotch: 27.2.0`, using the same `gh api -X PUT repos/JianyueLab/homebrew-tap/contents/Casks/notchnotch.rb` call as 27.1.11.

- [ ] **Step 4: nix-config — pin 27.2.0, link both plugins on the Macs**

In `~/Documents/nix-src/nix-config/flake.nix`, change the `notchnotch` input URL to `github:JianyueLab-Org/notch/v27.2.0`, and add after it:

```nix
    # NotchNotch's Agent Detection plugin: the signed release zip, since the
    # binary must carry the Developer ID signature.
    notchnotch-agents = {
      url = "https://github.com/JianyueLab-Org/notch/releases/download/v27.2.0/NotchNotchAgents-27.2.0.zip";
      flake = false;
    };
```

In `home/jhl/common/optional/ai/omp.nix`, replace the Darwin-only block with:

```nix
      # NotchNotch plugins (pinned inputs). Only the Macs run the app.
      # The omp extension posts turn ends; the manifest directories register
      # both plugins with the app's plugin host.
      // lib.optionalAttrs hostSpec.isDarwin {
        ".omp/agent/extensions/notchnotch.ts".source = "${inputs.notchnotch}/plugins/omp/notchnotch.ts";
        "Library/Application Support/NotchNotch/Plugins/co.jianyuelab.notchnotch.omp".source = "${inputs.notchnotch}/plugins/omp";
        "Library/Application Support/NotchNotch/Plugins/co.jianyuelab.notchnotch.agents".source = "${inputs.notchnotch-agents}";
      };
```

Run:

```bash
cd ~/Documents/nix-src/nix-config
nix flake lock --update-input notchnotch
nix flake lock
nix run nixpkgs#alejandra -- -q home/jhl/common/optional/ai/omp.nix
nix build --no-link .#darwinConfigurations.jhlsMacBookPro.system
nix eval --json '.#homeConfigurations."jhl@jhlsTokyoDesktop".config.home.file' --apply 'f: builtins.filter (n: builtins.match ".*(NotchNotch|notchnotch).*" n != null) (builtins.attrNames f)'
```

Expected: the build succeeds; the Linux eval prints `[]`.

A tarball/zip flake input strips a single top-level directory, so the input root *is* the plugin directory (`manifest.json` and `agents` at the top). Link it without a suffix:

```nix
        "Library/Application Support/NotchNotch/Plugins/co.jianyuelab.notchnotch.agents".source = "${inputs.notchnotch-agents}";
```

Confirm with `ls "$(nix eval --raw --impure --expr '(builtins.getFlake (toString ./.)).inputs.notchnotch-agents.outPath')"`: expected `agents  manifest.json`.

```bash
git add flake.nix flake.lock home/jhl/common/optional/ai/omp.nix
git commit -m "feat(omp): link NotchNotch 27.2.0 omp and agent plugins on the Macs"
```

- [ ] **Step 5: Clean up**

```bash
rm -rf .temp/rel .temp/plugin-checks
```
