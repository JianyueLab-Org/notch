//
//  PluginsSettingsSection.swift
//  NotchNotch
//
//  Settings → Plugins: the HTTP listener and one row per discovered plugin.
//

import AppKit
import SwiftUI

struct PluginsSettingsSection: View {
    @ObservedObject private var host = PluginHost.shared
    @ObservedObject private var activity = ActivityHub.shared
    @ObservedObject private var loc = LocalizationManager.shared

    var body: some View {
        VStack(spacing: 14) {
            httpCard
            if host.plugins.isEmpty {
                Text(L10n.tr(.settingsPluginsEmpty))
                    .font(.system(size: 11.5))
                    .foregroundStyle(JYLTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .jylCard()
            } else {
                ForEach(host.plugins) { record in
                    row(record)
                }
            }
            actions
        }
    }

    private var httpCard: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr(.settingsPluginsHTTPTitle))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(JYLTheme.textPrimary)
                Text(L10n.tr(.settingsPluginsHTTPDesc))
                    .font(.system(size: 11))
                    .foregroundStyle(JYLTheme.textSecondary)
                Text(listenerText)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(host.listenerStatus == .failed ? JYLTheme.error : JYLTheme.textMuted)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { host.isHTTPEnabled }, set: { host.setHTTPEnabled($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(14)
        .jylCard()
    }

    private var listenerText: String {
        switch host.listenerStatus {
        case .ready: return L10n.tr(.agentListenerReady)
        case .starting: return L10n.tr(.agentListenerStarting)
        case .failed: return L10n.tr(.agentListenerFailed)
        case .stopped: return L10n.tr(.commonDisabled)
        }
    }

    private func row(_ record: PluginRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(record.manifest?.displayName(isChinese: loc.isChinese) ?? record.id)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(JYLTheme.textPrimary)
                if let manifest = record.manifest {
                    Text(manifest.version)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(JYLTheme.textMuted)
                    Text(L10n.tr(manifest.kind == .managed ? .pluginKindManaged : .pluginKindExternal))
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(JYLTheme.textSecondary)
                }
                Text(statusText(record))
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(statusColor(record))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(statusColor(record).opacity(0.15)))
                Spacer()
                if record.manifest != nil {
                    Toggle("", isOn: Binding(get: { host.isEnabled(record.id) }, set: { host.setEnabled(record.id, $0) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }
            Text(record.id)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(JYLTheme.textMuted)
            if case .invalid(let reason) = record.status {
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundStyle(JYLTheme.error)
            }
            if !record.stderrTail.isEmpty {
                Text(record.stderrTail.joined(separator: "\n"))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(JYLTheme.textSecondary)
                    .lineLimit(20)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .jylCard()
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button(L10n.tr(.settingsPluginsOpenFolder)) {
                NSWorkspace.shared.open(host.directory)
            }
            Button(L10n.tr(.settingsPluginsReload)) {
                host.reload()
            }
            Spacer()
            Button(L10n.tr(.settingsPluginsTestAlert)) {
                activity.triggerAlert(
                    ActivityAlert(sessionKey: "test/alert", label: "NotchNotch", state: .waitingUser,
                                  title: loc.isChinese ? "需要确认权限" : "Permission Required", pid: nil, timestamp: Date()),
                    autoDismissAfter: 5
                )
            }
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
    }

    /// An external plugin has no process here; its state is whether its
    /// messages are accepted.
    private func statusText(_ record: PluginRecord) -> String {
        switch record.status {
        case .running: return L10n.tr(.pluginStatusRunning)
        case .stopped: return L10n.tr(.pluginStatusStopped)
        case .crashed: return L10n.tr(.pluginStatusCrashed)
        case .invalid: return L10n.tr(.pluginStatusInvalid)
        case .external: return L10n.tr(host.isEnabled(record.id) ? .commonEnabled : .commonDisabled)
        }
    }

    private func statusColor(_ record: PluginRecord) -> Color {
        switch record.status {
        case .running: return JYLTheme.success
        case .external: return host.isEnabled(record.id) ? JYLTheme.success : JYLTheme.textMuted
        case .stopped: return JYLTheme.textMuted
        case .crashed, .invalid: return JYLTheme.error
        }
    }
}
