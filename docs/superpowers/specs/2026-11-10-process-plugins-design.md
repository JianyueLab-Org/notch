# Process Plugins Design

Supersedes `2026-09-13-plugin-system-design.md` and `../plans/2026-09-13-module-registry.md`.

## Goal

The app core keeps the notch UI and a plugin API. Agent detection and omp support leave the core and
become plugins. The released app contains no agent-specific detection code.

## Decisions

- Plugins are separate processes. No loadable code, no JavaScript runtime.
- The core manages a plugin directory and launches managed plugins.
- Managed plugins talk JSON lines over stdin/stdout. External plugins POST to `127.0.0.1:7823`.
  Both use one message schema.
- The omp plugin is the omp extension only. The core and the agent plugin contain no omp code.
- Focus (pid → hosting GUI app, tmux case included) stays in the core.
- Legacy HTTP fields stay accepted.
- Existing settings migrate on first launch.

## Architecture

```
NotchNotch.app (core)
  PluginHost     manifest scan, launch, restart with backoff, stop
  ActivityHub    sessions, pid dedup, active-session priority, alert queue
  HTTP listener  127.0.0.1:7823, POST /event
  UI             ear, alert bar, focus, Settings → Plugins

agent plugin (managed, separate executable)   ps polling, agent matching, state inference
omp plugin   (external, omp extension)        agent_start / agent_end with title and pid
```

### Core components

- `Plugins/PluginManifest.swift`: decode and validate `manifest.json`.
- `Plugins/PluginHost.swift`: `@MainActor`. Discovers plugins, owns enablement (UserDefaults),
  launches managed plugins with `Process`, reads stdout on a background queue, restarts on exit.
- `Plugins/PluginMessage.swift`: `nonisolated`, `Sendable`. Message types and decoding, including
  the legacy HTTP field mapping. Pure; checkable from a standalone script.
- `Activity/ActivityHub.swift`: `@MainActor`, `ObservableObject`. Replaces the session, priority and
  alert logic of `AgentHarnessController`. Publishes `sessions`, `activeSession`, `currentAlert`.
- `Activity/ActivityFocus.swift`: the existing `DarwinProcessHelper` focus code (PPID climb, tmux
  client lookup, terminal fallback list).
- `Agent/AgentHTTPServer.swift`: kept; renamed to `Plugins/PluginHTTPServer.swift`.

`NotchWindowController.observeLiveActivities()` and `reload()` read `ActivityHub` instead of
`AgentHarnessController`. Views read `ActivityHub`.

### Removed from the core

`AgentProcessMatcher.swift`, `OmpSession.swift`, the `ps` polling, CPU inference, quiet-poll
counting, `processDetailsCache`, and the agent-specific Settings toggles. `AgentHarnessController`
is deleted.

## Plugin directory

`~/Library/Application Support/NotchNotch/Plugins/<id>/manifest.json`

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

- `id`: reverse-DNS, unique. The directory name is not authoritative.
- `kind`: `managed` (core launches `executable`, relative to the plugin directory) or `external`
  (no `executable`; the core only registers it).
- `apiVersion`: must equal the core's. A mismatch disables the plugin with a visible reason.
- A symlinked plugin directory or manifest is followed, so nix can link store paths.
- An invalid manifest is listed in Settings with its error and never launched.

## Messages

One JSON object per line on stdio; one object per POST body on HTTP.

| type | direction | fields |
|---|---|---|
| `hello` | core → plugin | `apiVersion`, `locale` |
| `config` | core → plugin | `values` (object; plugin-defined) |
| `session.update` | plugin → core | `id`, `state`, `label`, `title?`, `pid?`, `cwd?`, `alert?` |
| `session.end` | plugin → core | `id`, `alert?` |

- `state`: `working`, `waitingUser`, `waitingSubagent`, `completed`, `idle`.
- `label`: agent name shown under the title, e.g. `Claude Code`, `omp`.
- `alert`: the plugin asks for an alert on this update. The core alerts only when `alert` is true.
- HTTP bodies may carry `plugin` (manifest id). A body without `plugin` belongs to the built-in
  `http` source.
- HTTP bodies without `type` are legacy: `state`, `agent`, `event`, `session_id`, `cwd`, `title`,
  `terminal`, `pid` map to `session.update` with the existing fuzzy state matching. Legacy bodies
  alert on the transitions the current code alerts on.
- Session keys are `<plugin id>/<id>`. A plugin cannot touch another plugin's sessions.
- Messages from a disabled or unregistered `plugin` id are dropped.

### Pid dedup

When two live sessions report the same `pid`, the session updated most recently from an `external`
or `http` source hides the `managed` one until it ends or is idle for 180 s. This replaces the
current `hasFreshHttpHook` logic.

## Lifecycle and errors

- Launch: enabled managed plugins start at app launch and on enable. The core writes `hello`, then
  `config`.
- Exit: restart after 1, 2, 4, 8, 16, 30, 30 … s. Five exits within 10 minutes mark the plugin
  `crashed` and stop restarts until it is re-enabled. All its sessions are removed at each exit.
- Stop: on disable or app quit, close stdin, then `SIGTERM`, then `SIGKILL` after 2 s.
- stderr: the last 20 lines are kept per plugin and shown in Settings.
- Invalid JSON lines and invalid messages are dropped and logged under `Log.plugins`.
- Reading and decoding run off the main actor; only decoded messages hop to `@MainActor`.

## Settings → Plugins

Replaces the agent section. One row per discovered plugin: name, version, kind, status (`running`,
`stopped`, `crashed`, `invalid`, `external`), enable toggle, last stderr lines. A global toggle
controls the HTTP listener. The 7823 bind status stays visible. New strings get keys in both
`L10n` tables.

## Agent plugin

- New target `NotchNotchAgents`: command-line tool, Swift 6, Foundation and Darwin only.
- Contents: `AgentProcessMatcher` (minus the omp rule), `ps` polling every 4 s, CPU inference with
  three quiet polls, `session.update` with `pid` and `cwd`, `session.end` with `alert: true` when a
  working or waiting process exits.
- Reads `config.values.pollInterval` when present.
- Released as `NotchNotchAgents-<version>.zip` with `manifest.json` and `agents`, Developer ID
  signed, hardened runtime.

## omp plugin

- `plugins/omp/manifest.json` (`kind: external`, id `co.jianyuelab.notchnotch.omp`) and
  `plugins/omp/notchnotch.ts`. `scripts/omp/` moves there.
- The extension sends `type: session.update` with `plugin`, `label: "omp"`, `title`, `pid`, `cwd`,
  and `alert: true` on `agent_end`. Main session only.
- nix-config links the manifest directory into the Plugins directory and the extension into
  `~/.omp/agent/extensions/` on the Macs.

## Migration

On first launch of 27.2.0:

- `agentProcessScanningEnabled` with the agent plugin installed: false disables the agent plugin; true leaves it at its default (enabled).
- `agentMonitoringEnabled` → HTTP listener toggle; false also disables the agent plugin.
- `agentMonitoringEnabled` is deleted after it is applied.
- `agentProcessScanningEnabled` is deleted once the agent plugin is installed and the value applied.

## Versioning

App, agent plugin and omp plugin all start at 27.2.0.

## Verification

- Standalone `swift` scripts in `.temp/`: manifest validation, message decoding, legacy mapping,
  pid dedup, backoff schedule.
- End to end: agent plugin installed into the Plugins directory shows a real Claude Code session;
  killing the plugin process restarts it and the fifth kill within 10 minutes shows `crashed`; a
  real omp turn with the new extension shows the title alert; legacy `curl` from the existing docs
  still alerts.
