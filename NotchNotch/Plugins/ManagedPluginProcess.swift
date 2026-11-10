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
    private var stderrPending = Data()
    private var stderrTail: [String] = []

    /// An unterminated stderr line keeps only this many bytes; the rest is dropped.
    static let stderrPendingLimit = 16 * 1024

    private let onMessage: @Sendable (ManagedPluginProcess, PluginMessage) -> Void
    private let onStderr: @Sendable (ManagedPluginProcess, [String]) -> Void
    private let onExit: @Sendable (ManagedPluginProcess, Int32) -> Void

    init(
        pluginID: String,
        executable: URL,
        workingDirectory: URL,
        onMessage: @escaping @Sendable (ManagedPluginProcess, PluginMessage) -> Void,
        onStderr: @escaping @Sendable (ManagedPluginProcess, [String]) -> Void,
        onExit: @escaping @Sendable (ManagedPluginProcess, Int32) -> Void
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
        // Empty data is EOF; the handler would otherwise fire continuously until termination.
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            self?.queue.async { self?.consumeStdout(chunk) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            self?.queue.async { self?.consumeStderr(chunk) }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            self?.queue.async {
                guard let self else { return }
                self.stdoutPipe.fileHandleForReading.readabilityHandler = nil
                self.stderrPipe.fileHandleForReading.readabilityHandler = nil
                self.onExit(self, status)
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

    /// App quit, step 1: closes stdin and sends SIGTERM before returning.
    func terminateNow() {
        queue.sync { [self] in
            try? stdinPipe.fileHandleForWriting.close()
            guard process.isRunning else { return }
            process.terminate()
        }
    }

    /// App quit, step 2: waits for exit until `deadline`, then SIGKILLs. Blocks
    /// the caller, because the app exits as soon as quit returns.
    func waitOrKill(until deadline: Date) {
        while queue.sync(execute: { process.isRunning }) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        queue.sync { [self] in
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    private func consumeStdout(_ chunk: Data) {
        for line in lines.append(chunk) {
            // The pipe names the plugin; an envelope `plugin` field is ignored here.
            // A session.update without `alert` is a legacy HTTP body, which only
            // the HTTP listener accepts.
            if let envelope = PluginMessageDecoder.decode(line), !Self.isLegacy(envelope.message) {
                onMessage(self, envelope.message)
            } else {
                Log.plugins.error("plugin \(self.pluginID, privacy: .public) wrote an invalid message")
            }
        }
    }

    private static func isLegacy(_ message: PluginMessage) -> Bool {
        if case .sessionUpdate(let update) = message { return update.alert == nil }
        return false
    }

    /// Lines are split on raw bytes, so a chunk boundary inside a UTF-8
    /// sequence cannot lose it; decoding repairs invalid bytes.
    private func consumeStderr(_ chunk: Data) {
        stderrPending.append(chunk)
        var parts = stderrPending.split(separator: 0x0A, omittingEmptySubsequences: false)
        stderrPending = Data(parts.removeLast().prefix(Self.stderrPendingLimit))
        guard !parts.isEmpty else { return }
        let newLines = parts.map { String(decoding: $0, as: UTF8.self) }
        stderrTail = Array((stderrTail + newLines).suffix(Self.stderrTailLines))
        onStderr(self, stderrTail)
    }
}
