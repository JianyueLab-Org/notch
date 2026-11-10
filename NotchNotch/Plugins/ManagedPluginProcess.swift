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
