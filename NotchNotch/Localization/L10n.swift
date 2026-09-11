//
//  L10n.swift
//  NotchNotch
//
//  Type-safe string table supporting dynamic Simplified Chinese and English lookup.
//

import Foundation

public enum L10nKey: String, CaseIterable, Sendable {
    // MARK: - Navigation Tabs
    case tabOverview
    case tabWeather
    case tabShelf
    case tabClipboard

    // MARK: - Weather Card
    case weatherHourly
    case weatherNow
    case weatherApparent
    case weatherHumidity
    case weatherRain
    case weatherJustUpdated
    case weatherUpdatedAt
    case weatherFetching
    case weatherRetry
    case weatherRefresh

    // MARK: - Media Player Card
    case mediaNotPlaying
    case mediaUnknownTrack
    case mediaUnknownArtist
    case mediaPlayerTitle

    // MARK: - Schedule Timeline Card
    case scheduleNoEvents
    case scheduleInProgress
    case scheduleUpcoming
    case scheduleRemaining
    case scheduleElapsed
    case scheduleAllDay

    // MARK: - Drop Shelf
    case shelfEmptyTitle
    case shelfEmptySubtitle
    case shelfClearAll
    case shelfRevealInFinder
    case shelfAirDrop
    case shelfItemsCount

    // MARK: - Clipboard History
    case clipboardEmptyTitle
    case clipboardCopied
    case clipboardClearAll
    case clipboardAgeJustNow

    // MARK: - Agent & HUD
    case agentWaitingUser
    case agentWaitingSubagent
    case agentWorking
    case agentJumpToTerminal
    case agentAlertDismiss

    // MARK: - Menu Bar Extra
    case menuOpenPanel
    case menuSettings
    case menuLaunchAtLogin
    case menuQuit

    // MARK: - Settings Navigation Tabs
    case settingsTabGeneral
    case settingsTabWeather
    case settingsTabAgent
    case settingsTabClipboard
    case settingsTabAbout

    // MARK: - Settings General
    case settingsGeneralLanguageTitle
    case settingsGeneralLanguageDesc
    case settingsGeneralLaunchTitle
    case settingsGeneralLaunchDesc
    case settingsGeneralLaunchApproved
    case settingsGeneralLaunchDisabled
    case settingsGeneralOpenLoginItems
    case settingsGeneralScheduleTitle
    case settingsGeneralScheduleDesc
    case settingsGeneralScheduleLeadTime
    case settingsGeneralScheduleStartLead
    case settingsGeneralScheduleEndLead

    // MARK: - Settings Weather
    case settingsWeatherMasterTitle
    case settingsWeatherMasterDesc
    case settingsWeatherEarTitle
    case settingsWeatherEarDesc
    case settingsWeatherLocationTitle
    case settingsWeatherLocationAuto
    case settingsWeatherLocationManual
    case settingsWeatherLocationInputPlaceholder
    case settingsWeatherLocationSaveBtn
    case settingsWeatherCurrentLocationLabel
    case settingsWeatherLocationNotResolved
    case settingsWeatherUnitsTitle
    case settingsWeatherUnitCelsius
    case settingsWeatherUnitFahrenheit
    case settingsWeatherIntervalTitle
    case settingsWeatherInterval15
    case settingsWeatherInterval30
    case settingsWeatherInterval60
    case settingsWeatherRefreshBtn
    case settingsWeatherLastUpdatedLabel

    // MARK: - Settings Agent
    case settingsAgentMasterTitle
    case settingsAgentMasterDesc
    case settingsAgentScanTitle
    case settingsAgentScanDesc
    case settingsAgentHookTitle
    case settingsAgentHookDesc
    case settingsAgentCopyHookBtn
    case settingsAgentHookCopied

    // MARK: - Settings Clipboard
    case settingsClipboardRetentionTitle
    case settingsClipboardRetentionDesc
    case settingsClipboardClearBtn
    case settingsClipboardHistoryCount

    // MARK: - Settings About
    case settingsAboutVersion
    case settingsAboutCopyright
    case settingsAboutLicense
    case settingsAboutSourceCode

    // MARK: - Common Badges & Actions
    case commonEnabled
    case commonDisabled
    case commonSave
    case commonCancel
    case commonClear
}

public struct L10n {

    private static let zhDictionary: [L10nKey: String] = [
        // Navigation Tabs
        .tabOverview: "概览",
        .tabWeather: "天气",
        .tabShelf: "暂存架",
        .tabClipboard: "剪贴板",

        // Weather Card
        .weatherHourly: "逐小时预报",
        .weatherNow: "现在",
        .weatherApparent: "体感",
        .weatherHumidity: "湿度",
        .weatherRain: "降水",
        .weatherJustUpdated: "刚刚更新",
        .weatherUpdatedAt: "%@ 更新",
        .weatherFetching: "获取天气信息中...",
        .weatherRetry: "点击重试",
        .weatherRefresh: "刷新天气",

        // Media Player
        .mediaNotPlaying: "未在播放媒体",
        .mediaUnknownTrack: "未知曲目",
        .mediaUnknownArtist: "未知艺术家",
        .mediaPlayerTitle: "媒体播放器",

        // Schedule Timeline
        .scheduleNoEvents: "今日暂无后续日程",
        .scheduleInProgress: "进行中",
        .scheduleUpcoming: "即将开始",
        .scheduleRemaining: "剩余 %@",
        .scheduleElapsed: "已进行 %@",
        .scheduleAllDay: "全天日程",

        // Drop Shelf
        .shelfEmptyTitle: "拖放文件暂存于此",
        .shelfEmptySubtitle: "可随时拖拽至其他窗口或终端",
        .shelfClearAll: "清空暂存架",
        .shelfRevealInFinder: "在访达中显示",
        .shelfAirDrop: "隔空投送",
        .shelfItemsCount: "%d 项文件",

        // Clipboard
        .clipboardEmptyTitle: "剪贴板历史为空",
        .clipboardCopied: "已复制到剪贴板",
        .clipboardClearAll: "清除全部记录",
        .clipboardAgeJustNow: "刚刚",

        // Agent & HUD
        .agentWaitingUser: "等待回复",
        .agentWaitingSubagent: "子任务执行中",
        .agentWorking: "AI 运行中",
        .agentJumpToTerminal: "跳转终端",
        .agentAlertDismiss: "忽略",

        // Menu Bar Extra
        .menuOpenPanel: "展开刘海面板",
        .menuSettings: "偏好设置...",
        .menuLaunchAtLogin: "开机自动启动",
        .menuQuit: "退出 NotchNotch",

        // Settings Tabs
        .settingsTabGeneral: "常规",
        .settingsTabWeather: "天气",
        .settingsTabAgent: "AI Agent",
        .settingsTabClipboard: "剪贴板",
        .settingsTabAbout: "关于",

        // Settings General
        .settingsGeneralLanguageTitle: "界面语言",
        .settingsGeneralLanguageDesc: "选择界面的显示语言，即时生效无需重启应用",
        .settingsGeneralLaunchTitle: "开机自动启动",
        .settingsGeneralLaunchDesc: "登录 macOS 系统时自动在后台启动 NotchNotch 刘海面板",
        .settingsGeneralLaunchApproved: "需系统授权",
        .settingsGeneralLaunchDisabled: "已在系统设置中禁用",
        .settingsGeneralOpenLoginItems: "打开系统登录项 ↗",
        .settingsGeneralScheduleTitle: "日历日程提醒",
        .settingsGeneralScheduleDesc: "在会议开始前和结束前通过刘海悬浮岛弹出提前提示",
        .settingsGeneralScheduleLeadTime: "日程提前提醒",
        .settingsGeneralScheduleStartLead: "开始前提前提醒",
        .settingsGeneralScheduleEndLead: "结束前提前提醒",

        // Settings Weather
        .settingsWeatherMasterTitle: "启用天气服务",
        .settingsWeatherMasterDesc: "通过 Open-Meteo 免费气象接口获取实时气象与逐小时预报",
        .settingsWeatherEarTitle: "在刘海折叠耳部显示天气",
        .settingsWeatherEarDesc: "无音乐播放且无高优先级警报时，在刘海两侧常驻展示气象图标与温度",
        .settingsWeatherLocationTitle: "定位模式与位置",
        .settingsWeatherLocationAuto: "自动定位 (GPS / IP)",
        .settingsWeatherLocationManual: "指定城市 (手动输入)",
        .settingsWeatherLocationInputPlaceholder: "输入城市名称（如：上海 或 Tokyo）",
        .settingsWeatherLocationSaveBtn: "保存并定位",
        .settingsWeatherCurrentLocationLabel: "当前定位城市",
        .settingsWeatherLocationNotResolved: "未获取",
        .settingsWeatherUnitsTitle: "温度单位",
        .settingsWeatherUnitCelsius: "摄氏度 (°C)",
        .settingsWeatherUnitFahrenheit: "华氏度 (°F)",
        .settingsWeatherIntervalTitle: "刷新频率",
        .settingsWeatherInterval15: "15 分钟",
        .settingsWeatherInterval30: "30 分钟 (推荐)",
        .settingsWeatherInterval60: "1 小时",
        .settingsWeatherRefreshBtn: "立即刷新数据",
        .settingsWeatherLastUpdatedLabel: "上次更新",

        // Settings Agent
        .settingsAgentMasterTitle: "AI Agent 监控",
        .settingsAgentMasterDesc: "实时感知终端中 Claude Code、Antigravity、Codex 等智能体生命周期",
        .settingsAgentScanTitle: "本地进程轮询扫描",
        .settingsAgentScanDesc: "无 Webhook 钩子时自动扫描系统进程树中的活跃 CLI 代理",
        .settingsAgentHookTitle: "Agent Webhook 挂载指令",
        .settingsAgentHookDesc: "在终端中运行以下指令可获得毫秒级实时生命周期推送",
        .settingsAgentCopyHookBtn: "复制 Hook 安装指令",
        .settingsAgentHookCopied: "已复制指令",

        // Settings Clipboard
        .settingsClipboardRetentionTitle: "历史记录保留数量",
        .settingsClipboardRetentionDesc: "自动记录复制的历史文本条目，超过限制时自动淘汰旧记录",
        .settingsClipboardClearBtn: "清空剪贴板历史",
        .settingsClipboardHistoryCount: "已记录 %d 条历史条目",

        // Settings About
        .settingsAboutVersion: "版本",
        .settingsAboutCopyright: "版权所有 © 2026 JianyueLab LTD.",
        .settingsAboutLicense: "开源许可证",
        .settingsAboutSourceCode: "源代码仓库",

        // Common Badges
        .commonEnabled: "已启用",
        .commonDisabled: "已关闭",
        .commonSave: "保存",
        .commonCancel: "取消",
        .commonClear: "清除"
    ]

    private static let enDictionary: [L10nKey: String] = [
        // Navigation Tabs
        .tabOverview: "Overview",
        .tabWeather: "Weather",
        .tabShelf: "Drop Shelf",
        .tabClipboard: "Clipboard",

        // Weather Card
        .weatherHourly: "Hourly Forecast",
        .weatherNow: "Now",
        .weatherApparent: "Feels Like",
        .weatherHumidity: "Humidity",
        .weatherRain: "Rain",
        .weatherJustUpdated: "Just updated",
        .weatherUpdatedAt: "Updated at %@",
        .weatherFetching: "Fetching weather data...",
        .weatherRetry: "Retry",
        .weatherRefresh: "Refresh Weather",

        // Media Player
        .mediaNotPlaying: "Not Playing",
        .mediaUnknownTrack: "Unknown Track",
        .mediaUnknownArtist: "Unknown Artist",
        .mediaPlayerTitle: "Media Player",

        // Schedule Timeline
        .scheduleNoEvents: "No upcoming events today",
        .scheduleInProgress: "In Progress",
        .scheduleUpcoming: "Upcoming",
        .scheduleRemaining: "%@ left",
        .scheduleElapsed: "%@ elapsed",
        .scheduleAllDay: "All-day event",

        // Drop Shelf
        .shelfEmptyTitle: "Drag & drop files here",
        .shelfEmptySubtitle: "Ready to drag out to apps or terminal",
        .shelfClearAll: "Clear Shelf",
        .shelfRevealInFinder: "Reveal in Finder",
        .shelfAirDrop: "AirDrop",
        .shelfItemsCount: "%d items",

        // Clipboard
        .clipboardEmptyTitle: "Clipboard history is empty",
        .clipboardCopied: "Copied to clipboard",
        .clipboardClearAll: "Clear All History",
        .clipboardAgeJustNow: "Just now",

        // Agent & HUD
        .agentWaitingUser: "Awaiting Reply",
        .agentWaitingSubagent: "Subagent Busy",
        .agentWorking: "Agent Working",
        .agentJumpToTerminal: "Jump to Terminal",
        .agentAlertDismiss: "Dismiss",

        // Menu Bar Extra
        .menuOpenPanel: "Open Notch Panel",
        .menuSettings: "Settings...",
        .menuLaunchAtLogin: "Launch at Login",
        .menuQuit: "Quit NotchNotch",

        // Settings Tabs
        .settingsTabGeneral: "General",
        .settingsTabWeather: "Weather",
        .settingsTabAgent: "AI Agent",
        .settingsTabClipboard: "Clipboard",
        .settingsTabAbout: "About",

        // Settings General
        .settingsGeneralLanguageTitle: "Interface Language",
        .settingsGeneralLanguageDesc: "Choose display language, applied instantly without restarting",
        .settingsGeneralLaunchTitle: "Launch at Login",
        .settingsGeneralLaunchDesc: "Automatically launch NotchNotch in the background when logging in",
        .settingsGeneralLaunchApproved: "Requires Approval",
        .settingsGeneralLaunchDisabled: "Disabled in System Settings",
        .settingsGeneralOpenLoginItems: "Open Login Items ↗",
        .settingsGeneralScheduleTitle: "Schedule Reminders",
        .settingsGeneralScheduleDesc: "Show advance alerts in the notch overlay before events start or end",
        .settingsGeneralScheduleLeadTime: "Event Advance Reminders",
        .settingsGeneralScheduleStartLead: "Reminder Before Start",
        .settingsGeneralScheduleEndLead: "Reminder Before End",

        // Settings Weather
        .settingsWeatherMasterTitle: "Enable Weather Service",
        .settingsWeatherMasterDesc: "Retrieve real-time conditions and hourly forecasts via Open-Meteo",
        .settingsWeatherEarTitle: "Show Weather in Notch Ears",
        .settingsWeatherEarDesc: "Display weather icon and temperature when idle without active media",
        .settingsWeatherLocationTitle: "Location & Geocoding",
        .settingsWeatherLocationAuto: "Auto (GPS / IP)",
        .settingsWeatherLocationManual: "Custom City (Manual)",
        .settingsWeatherLocationInputPlaceholder: "Enter city name (e.g. Shanghai or Tokyo)",
        .settingsWeatherLocationSaveBtn: "Save & Locate",
        .settingsWeatherCurrentLocationLabel: "Resolved Location",
        .settingsWeatherLocationNotResolved: "Not Resolved",
        .settingsWeatherUnitsTitle: "Temperature Unit",
        .settingsWeatherUnitCelsius: "Celsius (°C)",
        .settingsWeatherUnitFahrenheit: "Fahrenheit (°F)",
        .settingsWeatherIntervalTitle: "Refresh Interval",
        .settingsWeatherInterval15: "15 Minutes",
        .settingsWeatherInterval30: "30 Minutes (Recommended)",
        .settingsWeatherInterval60: "1 Hour",
        .settingsWeatherRefreshBtn: "Refresh Now",
        .settingsWeatherLastUpdatedLabel: "Last Updated",

        // Settings Agent
        .settingsAgentMasterTitle: "AI Agent Monitoring",
        .settingsAgentMasterDesc: "Track local CLI agents like Claude Code, Antigravity, and Codex in real time",
        .settingsAgentScanTitle: "Background Process Scanning",
        .settingsAgentScanDesc: "Scan process trees for active agent sessions when webhook is not connected",
        .settingsAgentHookTitle: "Agent Webhook Command",
        .settingsAgentHookDesc: "Run this command in terminal to enable sub-millisecond lifecycle push",
        .settingsAgentCopyHookBtn: "Copy Hook Command",
        .settingsAgentHookCopied: "Command Copied",

        // Settings Clipboard
        .settingsClipboardRetentionTitle: "History Retention Limit",
        .settingsClipboardRetentionDesc: "Automatically record clipboard entries and discard oldest when exceeded",
        .settingsClipboardClearBtn: "Clear Clipboard History",
        .settingsClipboardHistoryCount: "%d items recorded",

        // Settings About
        .settingsAboutVersion: "Version",
        .settingsAboutCopyright: "Copyright © 2026 JianyueLab LTD.",
        .settingsAboutLicense: "License",
        .settingsAboutSourceCode: "Source Repository",

        // Common Badges
        .commonEnabled: "Enabled",
        .commonDisabled: "Disabled",
        .commonSave: "Save",
        .commonCancel: "Cancel",
        .commonClear: "Clear"
    ]

    // MARK: - Public Lookup Methods

    @MainActor
    public static func tr(_ key: L10nKey) -> String {
        let code = LocalizationManager.shared.activeCode
        return string(for: key, languageCode: code)
    }

    @MainActor
    public static func tr(_ key: L10nKey, _ args: CVarArg...) -> String {
        let code = LocalizationManager.shared.activeCode
        let format = string(for: key, languageCode: code)
        return String(format: format, arguments: args)
    }

    public static func string(for key: L10nKey, languageCode: String) -> String {
        if languageCode.hasPrefix("zh") {
            return zhDictionary[key] ?? enDictionary[key] ?? key.rawValue
        } else {
            return enDictionary[key] ?? zhDictionary[key] ?? key.rawValue
        }
    }

    public static func format(key: L10nKey, languageCode: String, _ args: CVarArg...) -> String {
        let format = string(for: key, languageCode: languageCode)
        return String(format: format, arguments: args)
    }
}
