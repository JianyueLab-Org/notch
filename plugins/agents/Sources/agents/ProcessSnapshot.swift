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
