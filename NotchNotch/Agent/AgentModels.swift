//
//  AgentModels.swift
//  NotchNotch
//
//  Data models for AI Agent harness status tracking and alerts.
//

import AppKit
import Foundation
import SwiftUI

enum AgentState: String, Codable, Equatable, Sendable {
    case working = "Working"
    case waitingUser = "WaitingUser"         // Needs human reply: permission, question, prompt
    case waitingSubagent = "WaitingSubagent" // Waiting for background subagent / delegated child task
    case completed = "Completed"             // Finished turn or task
    case idle = "Idle"                       // Inactive / session ready

    var isWaiting: Bool {
        self == .waitingUser || self == .waitingSubagent
    }

    var displayName: String {
        switch self {
        case .working: return "Working"
        case .waitingUser: return "Reply Needed"
        case .waitingSubagent: return "Subagent Active"
        case .completed: return "Completed"
        case .idle: return "Idle"
        }
    }

    var shortTag: String {
        switch self {
        case .working: return "BUSY"
        case .waitingUser: return "REPLY"
        case .waitingSubagent: return "SUB"
        case .completed: return "DONE"
        case .idle: return "IDLE"
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

struct AgentSession: Identifiable, Equatable, Sendable {
    let id: String
    var agent: String           // e.g. "Claude", "Antigravity", "Codex", "OpenCode"
    var state: AgentState
    var event: String           // e.g. "PreToolUse", "Notification", "Stop"
    var title: String           // Prompt or task summary
    var cwd: String             // Working directory
    var terminal: String        // e.g. "Ghostty", "Terminal", "tmux", "iTerm"
    var pid: Int?               // Process ID
    var lastUpdated: Date

    var shortCwd: String {
        if cwd.isEmpty { return "" }
        let home = NSHomeDirectory()
        if cwd.hasPrefix(home) {
            return "~" + cwd.dropFirst(home.count)
        }
        return (cwd as NSString).lastPathComponent
    }
}

struct AgentAlert: Equatable, Sendable {
    let id = UUID()
    let sessionId: String
    let agent: String
    let state: AgentState
    let title: String
    let detail: String
    let terminal: String
    let pid: Int?
    let timestamp: Date

    var isUrgent: Bool {
        state == .waitingUser
    }
}
