//
//  AccessibilityNowPlayingSource.swift
//  NotchNotch
//
//  Reads now-playing state out of Control Center's menu bar module over the
//  Accessibility API, and drives transport with synthesised media keys.
//
//  Why this rather than MediaRemote: MediaRemote is gated. Verified on macOS 27
//  — the same probe returns full metadata when run through Apple's signed
//  `swift` interpreter and an EMPTY dictionary from both an ad-hoc-signed
//  binary and this app signed with a Developer ID. No entitlement, no data.
//
//  The trade-off is that this needs the user to grant Accessibility, and that
//  it reads a UI surface rather than a data API — so the parsing below is
//  defensive and logs what it actually saw.
//

import AppKit
import ApplicationServices
import OSLog

@MainActor
final class AccessibilityNowPlayingSource: NowPlayingSource {

    var onChange: ((NowPlaying?) -> Void)?

    private(set) var authorization: NowPlayingAuthorization = .needsPermission(
        "NotchNotch needs Accessibility access to read what's playing and to control it.")

    var isAvailable: Bool { authorization == .granted }

    private var pollTask: Task<Void, Never>?
    private var didDumpTree = false
    private var lastLoggedTitle: String??

    // MARK: - Lifecycle

    func start() {
        refreshAuthorization()
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refreshAuthorization()
                if self.isAvailable {
                    self.refresh()
                } else {
                    self.onChange?(nil)
                }
                // Poll slowly while locked out — we are only waiting for the
                // user to flip a switch in System Settings.
                let interval = self.isAvailable
                    ? NotchConfiguration.accessibilityPollInterval
                    : NotchConfiguration.accessibilityAuthorizationPollInterval
                try? await Task.sleep(for: interval)
            }
        }
        Log.media.notice("media: Accessibility source started (trusted=\(AXIsProcessTrusted(), privacy: .public))")
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        Log.media.notice("media: Accessibility source stopped")
    }

    func send(_ command: MediaCommand) {
        MediaKeyTransport.post(command)
        // Media keys take a moment to be reflected in Control Center's UI.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, self.isAvailable else { return }
            self.refresh()
        }
    }

    /// Shows the system's own "grant access" prompt. Safe to call repeatedly —
    /// macOS only surfaces the dialog once per app, after which it silently
    /// returns the current state and the user must use System Settings.
    func requestAuthorization() {
        // The SDK exposes `kAXTrustedCheckOptionPrompt` as a global `var`,
        // which Swift 6 rejects as shared mutable state. Its value is this
        // string, so use it directly rather than reaching for the global.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refreshAuthorization()
    }

    private func refreshAuthorization() {
        let trusted = AXIsProcessTrusted()
        let next: NowPlayingAuthorization = trusted
            ? .granted
            : .needsPermission("NotchNotch needs Accessibility access to read what's playing and to control it.")
        guard next != authorization else { return }
        authorization = next
        Log.media.notice("media: accessibility authorization -> \(trusted ? "granted" : "denied", privacy: .public)")
    }

    // MARK: - Reading

    private func refresh() {
        Task.detached(priority: .utility) { [weak self] in
            let track = Self.fetchControlCenterTrack()
            await self?.report(track)
        }
    }

    private nonisolated static func fetchControlCenterTrack() -> NowPlaying? {
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.controlcenter").first else {
            return nil
        }
        let controlCenter = AXUIElementCreateApplication(app.processIdentifier)
        guard let item = findNowPlayingElement(under: controlCenter) else {
            return nil
        }
        return makeTrack(from: item)
    }

    /// Control Center exposes its menu bar modules as children of the app
    /// element. We look for the one that identifies itself as now-playing,
    /// falling back to a description match for localisations that rename it.
    private nonisolated static func findNowPlayingElement(under root: AXUIElement) -> AXUIElement? {
        var queue = [root]
        var head = 0
        while head < queue.count && head < 400 {
            let element = queue[head]
            head += 1

            let identifier = string(element, kAXIdentifierAttribute) ?? ""
            let description = string(element, kAXDescriptionAttribute) ?? ""
            let title = string(element, kAXTitleAttribute) ?? ""
            let value = string(element, kAXValueAttribute) ?? ""
            let haystack = "\(identifier) \(description) \(title) \(value)".lowercased()
            if haystack.contains("nowplaying") || haystack.contains("now playing") || haystack.contains("播放") || haystack.contains("再生") {
                Log.media.notice("media: AX matched element: \(identifier, privacy: .public)")
                return element
            }
            queue.append(contentsOf: children(of: element))
        }
        return nil
    }

    private nonisolated static func makeTrack(from element: AXUIElement) -> NowPlaying? {
        let title = string(element, kAXTitleAttribute) ?? ""
        let description = string(element, kAXDescriptionAttribute) ?? ""
        let value = string(element, kAXValueAttribute) ?? ""
        let help = string(element, kAXHelpAttribute) ?? ""

        let candidates = [value, description, title, help].filter { !$0.isEmpty }
        guard let text = candidates.first else { return nil }

        // Control Center writes "Title — Artist" (em dash) in most locales,
        // or "Title - Artist" (hyphen) in others.
        let parts: [String]
        if text.contains(" — ") {
            parts = text.components(separatedBy: " — ")
        } else if text.contains(" - ") {
            parts = text.components(separatedBy: " - ")
        } else {
            parts = [text]
        }
        let trackTitle = parts.first?.trimmingCharacters(in: .whitespaces) ?? text
        let artist = parts.count > 1
            ? parts.dropFirst().joined(separator: " — ").trimmingCharacters(in: .whitespaces)
            : ""

        return NowPlaying(title: trackTitle,
                          artist: artist,
                          album: "",
                          isPlaying: true,
                          duration: 0,
                          reportedElapsed: 0,
                          reportedAt: Date(),
                          playbackRate: 0,
                          artworkIdentifier: nil,
                          artwork: nil,
                          clientBundleIdentifier: nil)
    }

    private func report(_ track: NowPlaying?) {
        if lastLoggedTitle != .some(track?.title) {
            lastLoggedTitle = .some(track?.title)
            Log.media.notice("media: AX now playing \(track?.title ?? "(nothing)", privacy: .public)")
        }
        onChange?(track)
    }

    // MARK: - AX helpers

    private nonisolated static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success
        else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private nonisolated static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    /// Logs the hierarchy so the parser can be written against reality.
    private func dump(_ element: AXUIElement, label: String, depth: Int, maxDepth: Int) {
        guard depth <= maxDepth else { return }
        let pad = String(repeating: "  ", count: depth)
        let role = Self.string(element, kAXRoleAttribute) ?? "?"
        let fields = [("id", kAXIdentifierAttribute), ("title", kAXTitleAttribute),
                      ("desc", kAXDescriptionAttribute), ("value", kAXValueAttribute)]
            .compactMap { name, key in Self.string(element, key).map { "\(name)=\($0)" } }
            .joined(separator: " ")
        Log.media.notice("axdump: \(pad, privacy: .public)\(role, privacy: .public) \(fields, privacy: .public)")
        for child in Self.children(of: element) {
            dump(child, label: label, depth: depth + 1, maxDepth: maxDepth)
        }
    }

    deinit { pollTask?.cancel() }
}
