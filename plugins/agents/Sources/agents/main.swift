//
//  main.swift
//  NotchNotch agent plugin
//
//  Launched by NotchNotch. Writes session messages to stdout, reads hello and
//  config from stdin, and exits when stdin closes so it never outlives the app.
//

import Foundation

@MainActor
final class AgentPlugin {
    private var scanner = AgentScanner()
    private var timer: DispatchSourceTimer?
    private var interval: TimeInterval = 4

    func start() {
        schedule()
    }

    func applyConfig(pollInterval: Double?) {
        guard let pollInterval, pollInterval != interval else { return }
        interval = pollInterval
        schedule()
    }

    private func schedule() {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.resume()
        self.timer = timer
    }

    private func poll() {
        guard let output = ProcessSnapshot.run() else { return }
        let entries = ProcessSnapshot.parse(output)
        for message in scanner.step(entries: entries, cwd: ProcessSnapshot.cwd(of:)) {
            FileHandle.standardOutput.write(Wire.line(message))
        }
    }
}

let plugin = AgentPlugin()
plugin.start()

Thread.detachNewThread {
    while let line = readLine() {
        let interval = Wire.pollInterval(fromConfigLine: line)
        DispatchQueue.main.async {
            MainActor.assumeIsolated { plugin.applyConfig(pollInterval: interval) }
        }
    }
    exit(0)
}

// Not dispatchMain(): it drains the main queue on a worker thread, and
// MainActor.assumeIsolated traps there. The main run loop drains it on the main thread.
RunLoop.main.run()
