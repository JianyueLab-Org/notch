//
//  AppleScriptExecutor.swift
//  NotchNotch
//
//  Runs AppleScript off the main thread for the scripting backends.
//
//  `executeAndReturnError` blocks for the whole Apple event round trip. A
//  pending Automation consent prompt or a hung player holds that for as long
//  as the event's timeout, so running it on the main actor froze the overlay.
//
//  NSAppleScript is not thread-safe, so every script — Spotify's and Music's —
//  runs on one serial queue, and compiled scripts never leave it. Results are
//  flattened into a Sendable reply on that queue before crossing back.
//

import Foundation

nonisolated struct AppleScriptReply: Sendable {
    /// `stringValue` of each list item, or of the single result. A missing
    /// value is "".
    var strings: [String]
    /// Raw bytes of each list item, or of the single result.
    var data: [Data]

    func string(at index: Int) -> String {
        strings.indices.contains(index) ? strings[index] : ""
    }
}

nonisolated enum AppleScriptOutcome: Sendable {
    case success(AppleScriptReply)
    case failure(code: Int, message: String)
}

nonisolated final class AppleScriptExecutor: @unchecked Sendable {

    static let shared = AppleScriptExecutor()

    private let queue = DispatchQueue(label: "co.jianyuelab.NotchNotch.applescript", qos: .utility)
    /// Confined to `queue`. Keyed by source; the set of scripts is small and fixed.
    private var compiled: [String: NSAppleScript] = [:]

    private init() {}

    func run(_ source: String) async -> AppleScriptOutcome {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.execute(source))
            }
        }
    }

    private func execute(_ source: String) -> AppleScriptOutcome {
        let script: NSAppleScript
        if let cached = compiled[source] {
            script = cached
        } else {
            guard let fresh = NSAppleScript(source: source) else {
                return .failure(code: 0, message: "could not create script")
            }
            var compileError: NSDictionary?
            guard fresh.compileAndReturnError(&compileError) else {
                return Self.failure(from: compileError)
            }
            compiled[source] = fresh
            script = fresh
        }

        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error { return Self.failure(from: error) }

        if result.descriptorType == typeAEList {
            let count = result.numberOfItems
            // AppleEvent list indices are 1-based.
            let items = count > 0 ? (1...count).map { result.atIndex($0) } : []
            return .success(AppleScriptReply(
                strings: items.map { $0?.stringValue ?? "" },
                data: items.map { $0?.data ?? Data() }))
        }
        return .success(AppleScriptReply(strings: [result.stringValue ?? ""], data: [result.data]))
    }

    private static func failure(from error: NSDictionary?) -> AppleScriptOutcome {
        .failure(code: error?[NSAppleScript.errorNumber] as? Int ?? 0,
                 message: error?[NSAppleScript.errorMessage] as? String ?? "?")
    }
}
