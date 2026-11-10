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
