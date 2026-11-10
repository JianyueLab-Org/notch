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

    /// Gets parent PID and command name of any process via proc_bsdinfo.
    static func getParentPID(of pid: pid_t) -> (ppid: pid_t, comm: String)? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let ret = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard ret > 0 else { return nil }
        let comm = withUnsafePointer(to: &info.pbi_comm) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 16) { cStr in
                String(cString: cStr)
            }
        }
        return (pid_t(info.pbi_ppid), comm)
    }

    /// Recursively climbs up the PPID hierarchy to discover the hosting GUI application
    /// (e.g. Ghostty, Zed, Terminal, iTerm2, VS Code, Cursor, Warp).
    static func findGUIApp(for pid: pid_t) -> NSRunningApplication? {
        var cur = pid
        var hitTmux = false
        var visited = Set<pid_t>()

        for _ in 0..<12 {
            if visited.contains(cur) || cur <= 1 { break }
            visited.insert(cur)

            if let app = NSRunningApplication(processIdentifier: cur), app.activationPolicy == .regular {
                return app
            }

            guard let parent = getParentPID(of: cur) else { break }
            if parent.comm.contains("tmux") {
                hitTmux = true
            }
            cur = parent.ppid
        }

        if hitTmux {
            if let tmuxApp = resolveTmuxClientGUIApp(for: pid) {
                return tmuxApp
            }
        }

        return nil
    }

    /// If agent is running inside a tmux session, finds the tmux client terminal's GUI application.
    static func resolveTmuxClientGUIApp(for agentPid: pid_t) -> NSRunningApplication? {
        let tmuxPaths = ["/opt/homebrew/bin/tmux", "/run/current-system/sw/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        guard let tmuxPath = tmuxPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: tmuxPath)
        task.arguments = ["list-clients", "-F", "#{client_pid}"]
        let pipe = Pipe()
        task.standardOutput = pipe
        let finished = DispatchGroup()
        finished.enter()
        task.terminationHandler = { _ in finished.leave() }
        do {
            try task.run()
            // A stuck tmux server would otherwise block whoever asked to focus the session.
            if finished.wait(timeout: .now() + 2) == .timedOut {
                task.terminate()
                // SIGTERM can be ignored too; never wait on it unbounded.
                _ = finished.wait(timeout: .now() + 0.5)
                return nil
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let str = String(data: data, encoding: .utf8) {
                for line in str.components(separatedBy: .newlines) {
                    if let clientPid = Int(line.trimmingCharacters(in: .whitespaces)), clientPid > 1 {
                        if let app = findGUIAppDirect(for: pid_t(clientPid)) {
                            return app
                        }
                    }
                }
            }
        } catch {
            finished.leave()
        }

        return nil
    }

    private static func findGUIAppDirect(for pid: pid_t) -> NSRunningApplication? {
        var cur = pid
        var visited = Set<pid_t>()
        for _ in 0..<10 {
            if visited.contains(cur) || cur <= 1 { break }
            visited.insert(cur)
            if let app = NSRunningApplication(processIdentifier: cur), app.activationPolicy == .regular {
                return app
            }
            guard let parent = getParentPID(of: cur) else { break }
            cur = parent.ppid
        }
        return nil
    }

    /// `kill(pid, 0)` probes liveness. `EPERM` still means the process exists.
    static func isProcessAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Terminals and editors the fallback may activate, in preference order.
    private static let knownTerminalBundleIDs = [
        "com.mitchellh.ghostty", "dev.zed.Zed", "com.googlecode.iterm2", "com.apple.Terminal",
        "dev.warp.Warp-Stable", "com.todesktop.230313mzl4w4u92", "com.microsoft.VSCode",
        "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm",
    ]

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
