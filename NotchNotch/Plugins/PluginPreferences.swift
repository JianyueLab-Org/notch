//
//  PluginPreferences.swift
//  NotchNotch
//
//  UserDefaults keys for plugins and the one-time move off the pre-plugin
//  agent settings. Pure, so `.temp/` scripts can compile it.
//

import Foundation

nonisolated enum PluginPreferences {
    static let httpEnabledKey = "co.jianyuelab.NotchNotch.httpListenerEnabled"
    static let agentsPluginID = "co.jianyuelab.notchnotch.agents"
    static let ompPluginID = "co.jianyuelab.notchnotch.omp"

    static let legacyMonitoringKey = "co.jianyuelab.NotchNotch.agentMonitoringEnabled"
    static let legacyScanningKey = "co.jianyuelab.NotchNotch.agentProcessScanningEnabled"

    static func enabledKey(_ pluginID: String) -> String {
        "co.jianyuelab.NotchNotch.plugin.\(pluginID).enabled"
    }

    /// Installing a plugin is the intent to run it, so an absent key means enabled.
    static func isEnabled(_ pluginID: String, in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: enabledKey(pluginID)) as? Bool ?? true
    }

    static func isHTTPEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: httpEnabledKey) as? Bool ?? true
    }

    /// The scanning key is kept until the agent plugin is installed, so its
    /// choice still applies when the plugin arrives after the upgrade.
    static func migrate(defaults: UserDefaults, installedPluginIDs: Set<String>) {
        if let monitoring = defaults.object(forKey: legacyMonitoringKey) as? Bool {
            defaults.set(monitoring, forKey: httpEnabledKey)
            defaults.removeObject(forKey: legacyMonitoringKey)
        }
        if let scanning = defaults.object(forKey: legacyScanningKey) as? Bool,
           installedPluginIDs.contains(agentsPluginID) {
            defaults.set(scanning, forKey: enabledKey(agentsPluginID))
            defaults.removeObject(forKey: legacyScanningKey)
        }
    }
}
