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
    case waiting = "Waiting"     // Needs user action: tool permission, question, confirmation
    case completed = "Completed" // Finished turn or task
    case idle = "Idle"           // Inactive / session ready

    var displayName: String {
        switch self {
        case .working: return "Working"
        case .waiting: return "Action Needed"
        case .completed: return "Completed"
        case .idle: return "Idle"
        }
    }

    var iconName: String {
        switch self {
        case .working: return "sparkles"
        case .waiting: return "exclamationmark.triangle.fill"
        case .completed: return "checkmark.circle.fill"
        case .idle: return "circle"
        }
    }

    var color: Color {
        switch self {
        case .working: return JYLTheme.info
        case .waiting: return JYLTheme.primary // Amber/Orange
        case .completed: return JYLTheme.success
        case .idle: return JYLTheme.textMuted
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
        state == .waiting
    }
}
