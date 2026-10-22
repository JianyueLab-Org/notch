//
//  AgentProcessMatcher.swift
//  NotchNotch
//
//  Pure classification of a `ps` snapshot into agent sessions. No AppKit and
//  no kernel calls, so it can be checked from a standalone `swift` script.
//

import Foundation

nonisolated struct ProcessRawEntry: Sendable {
    let pid: Int
    let ppid: Int
    let cpu: Double
    let state: String
    let tty: String
    let comm: String
    let args: String
}

/// One agent after de-duplication. `memberPids` is the agent's own process plus
/// every matched descendant folded into it: an npm `node …/bin/codex` launcher
/// and its native `vendor/…/codex` child are one session, not two.
nonisolated struct MatchedAgentProcess: Sendable, Equatable {
    let name: String
    let pid: Int
    let memberPids: Set<Int>
}

nonisolated enum AgentProcessMatcher {

    /// One `ps` row, lowercased and tokenized once.
    struct ProcessCommand {
        let comm: String
        let args: String
        let tokens: [String]
        let hasTTY: Bool

        init(comm: String, args: String, tty: String) {
            self.comm = comm.lowercased()
            self.args = args.lowercased()
            self.tokens = self.args.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            // `ps` prints `??` for a process with no controlling terminal.
            self.hasTTY = !(tty.isEmpty || tty == "??" || tty == "-")
        }
    }

    /// Runtimes and package runners whose script argument is the real program.
    static let launchers: Set<String> = [
        "node", "nodejs", "python", "python3", "bun", "deno", "npx", "bunx", "npm", "pnpm", "yarn",
    ]

    /// Package-manager verbs between the launcher and the script: `bun run grok`, `pnpm dlx codex`.
    static let launcherSubcommands: Set<String> = ["run", "dlx", "exec", "x", "--"]

    /// Launcher options that consume the next token: `node -r ts-node/register x`.
    static let launcherOptionsWithValue: Set<String> = [
        "-r", "--require", "--import", "--loader", "--experimental-loader", "-p", "--package",
        "--preload", "--cwd", "-c", "--config", "--filter", "--dir",
    ]

    static func agentName(comm: String, args: String, tty: String) -> String? {
        agentName(for: ProcessCommand(comm: comm, args: args, tty: tty))
    }

    /// Rules are ordered; the first match names the agent. Grok and Codex come
    /// first because they are matched exactly, while the rules after them are
    /// substring matches that would also fire on a path or argument mentioning
    /// another agent's name.
    static func agentName(for cmd: ProcessCommand) -> String? {
        if isScanNoise(cmd) || isInsideAppBundle(cmd.args) { return nil }

        // 1–2. Grok / Codex: executable name only, never a substring of the
        // command line. Shell wrappers that only mention the name inside a
        // script (Grok's `__grok_*` shim) must not match. Without a controlling
        // terminal the process is a daemon, an MCP server or a `codex exec`
        // run by another program, not an interactive session, and would pin
        // the island on REPLY.
        let names = executableNames(cmd)
        for name in names {
            let agent: String
            switch name {
            case "grok": agent = "Grok"
            case "codex": agent = "Codex"
            default: continue
            }
            return cmd.hasTTY ? agent : nil
        }

        // 3. Claude Code / Claude CLI
        if (cmd.comm.contains("claude") || cmd.args.contains("claude")) && !cmd.args.contains("--chrome-native-host") {
            return (cmd.args.contains("claude-agent-sdk") || cmd.args.contains("claude-acp"))
                ? "Claude (Zed ACP)"
                : "Claude Code"
        }

        // 4. Antigravity CLI
        if cmd.comm == "agy" || cmd.args.contains("agy ") || cmd.args.hasPrefix("agy") || cmd.args.contains("/agy ") || cmd.args.contains("antigravity") {
            return "Antigravity"
        }

        // 5. OpenCode CLI
        if cmd.comm == "opencode" || cmd.args.contains("opencode") || cmd.args.contains("open-code") {
            return "OpenCode"
        }

        // 6. Aider CLI
        if names.contains("aider") || cmd.args.contains("aider ") || cmd.args.hasPrefix("aider") {
            return "Aider"
        }

        return nil
    }

    /// Matches every row, then folds each match into its topmost matched
    /// ancestor, so a launcher and its child, or an agent run as another
    /// agent's tool, count once.
    static func discover(_ entries: [ProcessRawEntry]) -> [MatchedAgentProcess] {
        var nameByPid: [Int: String] = [:]
        for entry in entries {
            if let name = agentName(comm: entry.comm, args: entry.args, tty: entry.tty) {
                nameByPid[entry.pid] = name
            }
        }
        guard !nameByPid.isEmpty else { return [] }

        var ppidByPid: [Int: Int] = [:]
        for entry in entries { ppidByPid[entry.pid] = entry.ppid }

        func topmostMatch(of pid: Int) -> Int {
            var top = pid
            var cur = ppidByPid[pid]
            var hops = 0
            while let parent = cur, parent > 1, hops < 64 {
                if nameByPid[parent] != nil { top = parent }
                cur = ppidByPid[parent]
                hops += 1
            }
            return top
        }

        var members: [Int: Set<Int>] = [:]
        for pid in nameByPid.keys {
            members[topmostMatch(of: pid), default: []].insert(pid)
        }
        return members
            .compactMap { root, pids in
                nameByPid[root].map { MatchedAgentProcess(name: $0, pid: root, memberPids: pids) }
            }
            .sorted { $0.pid < $1.pid }
    }

    /// CPU of the agent's own processes plus their direct non-member children
    /// (tools), and whether any of those children is busy.
    static func cpuUsage(of agent: MatchedAgentProcess, in entries: [ProcessRawEntry]) -> (total: Double, hasActiveTool: Bool) {
        var total = 0.0
        var hasActiveTool = false
        for entry in entries {
            if agent.memberPids.contains(entry.pid) {
                total += entry.cpu
            } else if agent.memberPids.contains(entry.ppid) {
                total += entry.cpu
                if entry.cpu > 0.1 { hasActiveTool = true }
            }
        }
        return (total, hasActiveTool)
    }

    // MARK: - Rules

    /// Skip the scanner's own grep and this app. A client whose arguments mention
    /// the repo name is still an agent and must not be filtered out.
    static func isScanNoise(_ cmd: ProcessCommand) -> Bool {
        let comm = cmd.comm, args = cmd.args
        if comm == "grep" || comm == "rg" || comm.hasSuffix("/grep") || comm.hasSuffix("/rg") {
            return true
        }
        if args == "grep" || args == "rg" || args.hasPrefix("grep ") || args.hasPrefix("rg ") {
            return true
        }
        return comm.contains("notchnotch")
    }

    /// A GUI app and its helpers (`/Applications/Grok Bot.app/Contents/MacOS/Grok Bot`,
    /// `…/Codex Helper (Renderer).app/…`) are never a CLI session. argv0 may contain
    /// spaces, so it cannot be cut out by whitespace: the bundle path has to start
    /// the command line and be reached before anything that looks like a second
    /// argument (` -flag` or ` /path`).
    static func isInsideAppBundle(_ lowerArgs: String) -> Bool {
        guard lowerArgs.hasPrefix("/"), let bundle = lowerArgs.range(of: ".app/contents/") else { return false }
        let argv0Prefix = lowerArgs[..<bundle.lowerBound]
        return !argv0Prefix.contains(" -") && !argv0Prefix.contains(" /")
    }

    /// `ps comm` is truncated to 16 characters, so `~/.codex/.../bin/codex` shows
    /// up there as `/Users/jhl/.code`; argv0 is the first token of `args`. Under a
    /// launcher the script is the first token that is not a subcommand, an option
    /// or an option's value.
    static func executableNames(_ cmd: ProcessCommand) -> [String] {
        var names: [String] = []
        if !cmd.comm.isEmpty { names.append(basename(cmd.comm)) }
        guard let argv0 = cmd.tokens.first else { return names }
        names.append(basename(argv0))
        guard names.contains(where: { launchers.contains($0) }) else { return names }

        var skipNext = false
        for token in cmd.tokens.dropFirst() {
            if skipNext {
                skipNext = false
                continue
            }
            if launcherSubcommands.contains(token) { continue }
            if token.hasPrefix("-") {
                skipNext = launcherOptionsWithValue.contains(token)
                continue
            }
            names.append(basename(token))
            break
        }
        return names
    }

    static func basename(_ token: String) -> String {
        var name = token.split(separator: "/").last.map(String.init) ?? token
        for suffix in [".js", ".mjs", ".cjs", ".exe"] where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
            break
        }
        return name
    }
}
