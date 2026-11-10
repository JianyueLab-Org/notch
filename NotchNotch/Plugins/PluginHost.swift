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
        // reload() migrates the pre-plugin keys, so the HTTP flag is read after it.
        reload()
        isHTTPEnabled = PluginPreferences.isHTTPEnabled(in: defaults)
        if isHTTPEnabled { startHTTP() }
    }

    // MARK: - Discovery

    /// Rescans the directory. Symlinked plugin directories (nix store paths)
    /// are followed. Running processes of plugins that disappeared are stopped.
    /// Migration runs on every scan, so a plugin installed while the app runs
    /// still picks up the pre-plugin settings. Enabled managed plugins that are
    /// not running, crashed or waiting out a restart delay are launched.
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
        PluginPreferences.migrate(defaults: defaults, installedPluginIDs: Set(records.compactMap { $0.manifest?.id }))
        for record in records where record.manifest?.kind == .managed
            && record.status != .crashed
            && processes[record.id] == nil
            && restartTasks[record.id] == nil
            && isEnabled(record.id) {
            launch(record.id)
        }
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
                // Already running: keep the live child and its status.
                guard processes[id] == nil else { return }
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

    /// App quit: stdin close and SIGTERM are sent before returning, because the
    /// process exits right after and an async stop would never run.
    func stopAll() {
        for id in Array(processes.keys) {
            restartTasks.removeValue(forKey: id)?.cancel()
            processes.removeValue(forKey: id)?.stopNow()
        }
        httpServer.stop()
    }

    // MARK: - Managed processes

    private func launch(_ id: String) {
        guard processes[id] == nil,
              let record = plugins.first(where: { $0.id == id }),
              let manifest = record.manifest, manifest.kind == .managed,
              let executable = manifest.executable else { return }

        // Callbacks name their process: a stopped child still in its stop grace
        // must not touch the instance that replaced it. The hop is
        // DispatchQueue.main, not Task, so callbacks stay FIFO (an update
        // before the end that follows it).
        let process = ManagedPluginProcess(
            pluginID: id,
            executable: record.directory.appendingPathComponent(executable),
            workingDirectory: record.directory,
            onMessage: { [weak self] process, message in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.processes[id] === process else { return }
                        self.hub.apply(message, pluginID: id, source: .managed)
                    }
                }
            },
            onStderr: { [weak self] process, tail in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.processes[id] === process else { return }
                        self.update(id) { $0.stderrTail = tail }
                    }
                }
            },
            onExit: { [weak self] process, status in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.processExited(id, process: process, status: status)
                    }
                }
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

    private func processExited(_ id: String, process: ManagedPluginProcess, status: Int32) {
        // Absent or replaced means stopProcess already took it out: an intended stop, not a crash.
        guard let current = processes[id], current === process else { return }
        processes[id] = nil
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
