//
//  ActivityState+Presentation.swift
//  NotchNotch
//

import SwiftUI

extension ActivityState {
    var displayName: String {
        let isZh = LocalizationManager.shared.isChinese
        switch self {
        case .working: return isZh ? "运行中" : "Working"
        case .waitingUser: return isZh ? "等待回复" : "Reply Needed"
        case .waitingSubagent: return isZh ? "子任务执行中" : "Subagent Active"
        case .completed: return isZh ? "已完成" : "Completed"
        case .idle: return isZh ? "空闲" : "Idle"
        }
    }

    var shortTag: String {
        let isZh = LocalizationManager.shared.isChinese
        switch self {
        case .working: return isZh ? "忙碌" : "BUSY"
        case .waitingUser: return isZh ? "回复" : "REPLY"
        case .waitingSubagent: return isZh ? "子项" : "SUB"
        case .completed: return isZh ? "完成" : "DONE"
        case .idle: return isZh ? "空闲" : "IDLE"
        }
    }

    var iconName: String {
        switch self {
        case .working: return "sparkles"
        case .waitingUser: return "exclamationmark.bubble.fill"
        case .waitingSubagent: return "arrow.triangle.branch"
        case .completed: return "checkmark.circle.fill"
        case .idle: return "circle"
        }
    }

    var color: Color {
        switch self {
        case .working: return JYLTheme.info
        case .waitingUser: return JYLTheme.primary // Amber
        case .waitingSubagent: return JYLTheme.chart3 // Purple / Lavender (#a78bfa)
        case .completed: return JYLTheme.success
        case .idle: return JYLTheme.textMuted
        }
    }

    var colorMuted: Color {
        switch self {
        case .working: return JYLTheme.infoMuted
        case .waitingUser: return JYLTheme.primaryMuted
        case .waitingSubagent: return Color(hex: "#a78bfa", opacity: 0.20)
        case .completed: return JYLTheme.successMuted
        case .idle: return Color.white.opacity(0.1)
        }
    }
}
