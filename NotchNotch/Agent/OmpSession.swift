//
//  OmpSession.swift
//  NotchNotch
//
//  Reads the conversation title of a running omp session. Pure file and path
//  logic, so it can be checked from a standalone `swift` script.
//

import Foundation

nonisolated enum OmpSession {

    /// Agent name used by both the process scanner and the omp extension, so a
    /// fresh hook session suppresses the scanned one for the same process.
    static let agentName = "omp"

    /// omp keeps its session transcript open for writing. The main session is
    /// `<dir>/<ISO timestamp>_<id>.jsonl`, where `<dir>` is `sessions/<cwd>` or a
    /// `--session-dir`. Subagent transcripts sit inside the session's own
    /// directory, `<dir>/<timestamp>_<id>/<Name>.jsonl`, and must not be taken
    /// for the conversation.
    static func isMainSessionFile(_ path: String) -> Bool {
        let components = path.split(separator: "/")
        guard components.count >= 2, let file = components.last, file.hasSuffix(".jsonl") else { return false }
        return isSessionName(file.dropLast(".jsonl".count))
            && !isSessionName(components[components.count - 2])
    }

    /// `2026-11-10T04-52-44-116Z_<id>`; a subagent's `<Name>` never starts with a date.
    private static func isSessionName(_ name: Substring) -> Bool {
        guard let separator = name.firstIndex(of: "_") else { return false }
        let timestamp = name[..<separator]
        return timestamp.count >= 20
            && timestamp.hasSuffix("Z")
            && timestamp.first?.isNumber == true
            && timestamp.contains("T")
            && name.index(after: separator) < name.endIndex
    }

    /// Line 1 of every session file is a padded `{"type":"title",...}` record that
    /// omp rewrites in place when the title changes. A read that races the
    /// rewrite fails to parse and yields nil, so callers keep the previous title.
    static func title(fromHead head: Data) -> String? {
        let line = head.prefix { $0 != UInt8(ascii: "\n") }
        guard let record = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              record["type"] as? String == "title",
              let title = (record["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }
        return title
    }

    static func title(ofSessionFile path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4096) else { return nil }
        return title(fromHead: head)
    }
}
