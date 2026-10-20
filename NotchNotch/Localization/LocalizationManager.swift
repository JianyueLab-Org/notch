//
//  LocalizationManager.swift
//  NotchNotch
//
//  Central manager for application language settings and runtime locale switching.
//

import AppKit
import Combine
import Foundation
import SwiftUI

public enum AppLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case system = "system"
    case zhHans = "zh-Hans"
    case en = "en"

    public var id: String { rawValue }

    @MainActor
    public var displayName: String {
        switch self {
        case .system:
            return LocalizationManager.shared.isChinese ? "跟随系统" : "System"
        case .zhHans:
            return "简体中文"
        case .en:
            return "English"
        }
    }
}

@MainActor
public final class LocalizationManager: ObservableObject {

    public static let shared = LocalizationManager()

    private nonisolated static let languageKey = "co.jianyuelab.NotchNotch.appLanguage"

    /// Language code for strings built off the main actor. Matches `activeCode`.
    public nonisolated static func currentLanguageCode() -> String {
        let raw = UserDefaults.standard.string(forKey: languageKey) ?? AppLanguage.system.rawValue
        switch AppLanguage(rawValue: raw) ?? .system {
        case .zhHans:
            return "zh-Hans"
        case .en:
            return "en"
        case .system:
            let preferred = Locale.preferredLanguages.first ?? "en"
            return preferred.lowercased().hasPrefix("zh") ? "zh-Hans" : "en"
        }
    }

    @Published public var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: Self.languageKey)
            recomputeActiveCode()
        }
    }

    /// The actual effective language code ("zh-Hans" or "en")
    @Published public private(set) var activeCode: String = "zh-Hans"

    public var isChinese: Bool {
        activeCode.hasPrefix("zh")
    }

    public var locale: Locale {
        Locale(identifier: activeCode)
    }

    public init() {
        let savedRaw = UserDefaults.standard.string(forKey: Self.languageKey)
        let resolved = savedRaw.flatMap(AppLanguage.init(rawValue:)) ?? .system
        self.language = resolved
        recomputeActiveCode()
    }

    public func setLanguage(_ lang: AppLanguage) {
        guard language != lang else { return }
        language = lang
    }

    private func recomputeActiveCode() {
        switch language {
        case .system:
            let preferred = Locale.preferredLanguages.first ?? "en"
            if preferred.lowercased().hasPrefix("zh") {
                activeCode = "zh-Hans"
            } else {
                activeCode = "en"
            }
        case .zhHans:
            activeCode = "zh-Hans"
        case .en:
            activeCode = "en"
        }
    }
}
