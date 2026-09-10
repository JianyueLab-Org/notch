//
//  SettingsView.swift
//  NotchNotch
//

import SwiftUI
import ServiceManagement

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "常规"
    case clipboard = "剪贴板"
    case about = "关于"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .general: return "gearshape.fill"
        case .clipboard: return "doc.on.doc.fill"
        case .about: return "info.circle.fill"
        }
    }
}

struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .general
    @ObservedObject private var clipboard = ClipboardManager.shared
    @ObservedObject private var launchAtLogin = LaunchAtLoginManager.shared

    @State private var showClearedAlert: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Header with Traffic-light clearance & Tab selector
            headerView

            Divider()
                .background(JYLTheme.border)

            // Tab Content
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 16) {
                    switch selectedTab {
                    case .general:
                        generalSection
                    case .clipboard:
                        clipboardSection
                    case .about:
                        aboutSection
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 500, height: 420)
        .background(JYLTheme.surface)
        .preferredColorScheme(.dark)
    }

    // MARK: - Header & Tab Bar

    private var headerView: some View {
        VStack(spacing: 12) {
            HStack {
                Text("NotchNotch 设置")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(JYLTheme.textPrimary)

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)

            // Segmented Tab Selector
            HStack(spacing: 6) {
                ForEach(SettingsTab.allCases) { tab in
                    let isSelected = selectedTab == tab
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedTab = tab
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: tab.iconName)
                                .font(.system(size: 11, weight: .semibold))
                            Text(tab.rawValue)
                                .font(.system(size: 11.5, weight: isSelected ? .bold : .medium, design: .rounded))
                        }
                        .foregroundStyle(isSelected ? JYLTheme.textPrimary : JYLTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(isSelected ? JYLTheme.neutral700 : JYLTheme.neutral800.opacity(0.6))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .strokeBorder(isSelected ? Color.white.opacity(0.15) : Color.clear, lineWidth: 0.5)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .background(JYLTheme.neutral950.opacity(0.6))
    }

    // MARK: - General Tab

    private var generalSection: some View {
        VStack(spacing: 14) {
            // Card 1: Launch at login
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(JYLTheme.neutral800)
                            .frame(width: 32, height: 32)
                        Image(systemName: "power.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(launchAtLogin.isEnabled ? JYLTheme.primary : JYLTheme.textSecondary)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("开机自动启动")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(JYLTheme.textPrimary)

                            Spacer()

                            if launchAtLogin.requiresApproval {
                                Text("需系统授权")
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                                    .foregroundStyle(JYLTheme.warning)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(JYLTheme.warning.opacity(0.15)))
                            } else {
                                Text(launchAtLogin.isEnabled ? "已启用" : "已关闭")
                                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                    .foregroundStyle(launchAtLogin.isEnabled ? JYLTheme.primary : JYLTheme.textMuted)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(launchAtLogin.isEnabled ? JYLTheme.primary.opacity(0.15) : JYLTheme.neutral800))
                            }
                        }

                        Text("登录 macOS 系统时自动在后台启动 NotchNotch 刘海面板")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(JYLTheme.textSecondary)
                    }
                }

                if launchAtLogin.requiresApproval {
                    HStack {
                        Text("系统登录项已被系统禁用，需前往系统设置手动开启。")
                            .font(.system(size: 10.5, weight: .regular))
                            .foregroundStyle(JYLTheme.warning)

                        Spacer()

                        Button("打开系统登录项 ↗") {
                            launchAtLogin.openLoginItemsSettings()
                        }
                        .font(.system(size: 10.5, weight: .semibold))
                        .buttonStyle(.link)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(JYLTheme.warning.opacity(0.08)))
                }

                HStack(spacing: 8) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.12)) {
                            launchAtLogin.setEnabled(false)
                        }
                    } label: {
                        Text("关闭")
                            .font(.system(size: 11, weight: !launchAtLogin.isEnabled ? .bold : .medium, design: .rounded))
                            .foregroundStyle(!launchAtLogin.isEnabled ? JYLTheme.textPrimary : JYLTheme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 26)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(!launchAtLogin.isEnabled ? JYLTheme.neutral700 : JYLTheme.neutral800)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .strokeBorder(!launchAtLogin.isEnabled ? Color.white.opacity(0.15) : Color.clear, lineWidth: 0.5)
                                    )
                            )
                    }
                    .buttonStyle(.plain)

                    Button {
                        withAnimation(.easeInOut(duration: 0.12)) {
                            launchAtLogin.setEnabled(true)
                        }
                    } label: {
                        Text("开启")
                            .font(.system(size: 11, weight: launchAtLogin.isEnabled ? .bold : .medium, design: .rounded))
                            .foregroundStyle(launchAtLogin.isEnabled ? JYLTheme.textPrimary : JYLTheme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 26)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(launchAtLogin.isEnabled ? JYLTheme.neutral700 : JYLTheme.neutral800)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .strokeBorder(launchAtLogin.isEnabled ? Color.white.opacity(0.15) : Color.clear, lineWidth: 0.5)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(JYLTheme.neutral900.opacity(0.7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(JYLTheme.border.opacity(0.6), lineWidth: 0.8)
                    )
            )

            // Card 2: Notch display re-detect
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(JYLTheme.neutral800)
                            .frame(width: 32, height: 32)
                        Image(systemName: "display.2")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(JYLTheme.textSecondary)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("屏幕与刘海适配")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(JYLTheme.textPrimary)

                        Text("插拔外接显示器或更改显示分辨率后，重新计算刘海位置与几何尺寸")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(JYLTheme.textSecondary)
                    }

                    Spacer()
                }

                Button {
                    NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text("重新检测刘海屏幕")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(JYLTheme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(JYLTheme.neutral800)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
                            )
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(JYLTheme.neutral900.opacity(0.7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(JYLTheme.border.opacity(0.6), lineWidth: 0.8)
                    )
            )
        }
    }

    // MARK: - Clipboard Tab

    private var clipboardSection: some View {
        VStack(spacing: 14) {
            // Card 1: Max items selector
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(JYLTheme.neutral800)
                            .frame(width: 32, height: 32)
                        Image(systemName: "doc.on.doc.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(JYLTheme.textSecondary)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("剪贴板历史保留上限")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(JYLTheme.textPrimary)

                            Spacer()

                            Text("\(clipboard.maxItems) 条")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(JYLTheme.primary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(JYLTheme.primary.opacity(0.15)))
                        }

                        Text("自动记录复制的文本内容，超出上限后将移除最旧记录")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(JYLTheme.textSecondary)
                    }
                }

                HStack(spacing: 8) {
                    ForEach(ClipboardManager.maxItemsOptions, id: \.self) { count in
                        let isSelected = clipboard.maxItems == count
                        Button {
                            withAnimation(.easeInOut(duration: 0.12)) {
                                clipboard.updateMaxItems(count)
                            }
                        } label: {
                            Text("\(count) 条")
                                .font(.system(size: 11, weight: isSelected ? .bold : .medium, design: .rounded))
                                .foregroundStyle(isSelected ? JYLTheme.textPrimary : JYLTheme.textSecondary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 28)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(isSelected ? JYLTheme.neutral700 : JYLTheme.neutral800)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .strokeBorder(isSelected ? Color.white.opacity(0.15) : Color.clear, lineWidth: 0.5)
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(JYLTheme.neutral900.opacity(0.7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(JYLTheme.border.opacity(0.6), lineWidth: 0.8)
                    )
            )

            // Card 2: Clear history
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(JYLTheme.neutral800)
                            .frame(width: 32, height: 32)
                        Image(systemName: "trash.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(JYLTheme.textSecondary)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("清空历史记录")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(JYLTheme.textPrimary)

                            Spacer()

                            Text("当前已存 \(clipboard.items.count) 条")
                                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                                .foregroundStyle(JYLTheme.textMuted)
                        }

                        Text("清空 NotchNotch 记录的全部剪贴板卡片，不会影响当前系统剪贴板")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(JYLTheme.textSecondary)
                    }
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        clipboard.clearAll()
                        showClearedAlert = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        showClearedAlert = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: showClearedAlert ? "checkmark" : "trash")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text(showClearedAlert ? "已清空" : "清空剪贴板记录")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(showClearedAlert ? JYLTheme.success : JYLTheme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(JYLTheme.neutral800)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
                            )
                    )
                }
                .buttonStyle(.plain)
                .disabled(clipboard.items.isEmpty)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(JYLTheme.neutral900.opacity(0.7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(JYLTheme.border.opacity(0.6), lineWidth: 0.8)
                    )
            )
        }
    }

    // MARK: - About Tab

    private var aboutSection: some View {
        VStack(spacing: 16) {
            // App Icon & Info
            VStack(spacing: 8) {
                if let appIcon = NSApp.applicationIconImage {
                    Image(nsImage: appIcon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .shadow(color: Color.black.opacity(0.4), radius: 8, y: 4)
                } else {
                    Image(systemName: "menubar.rectangle")
                        .font(.system(size: 40))
                        .foregroundStyle(JYLTheme.primary)
                }

                Text("NotchNotch")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(JYLTheme.textPrimary)

                let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
                Text("Version \(version) (macOS)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(JYLTheme.textMuted)

                Text("MacBook Pro 刘海专属生产力增强面板")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(JYLTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 4)

            Divider()
                .background(JYLTheme.border)

            // Links & Actions
            VStack(spacing: 8) {
                Button {
                    if let url = URL(string: "https://github.com/JianyueLab/notch") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "link")
                            .font(.system(size: 11, weight: .semibold))
                        Text("访问 GitHub 开源仓库 ↗")
                            .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    }
                    .foregroundStyle(JYLTheme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(JYLTheme.neutral800)
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
                            )
                    )
                }
                .buttonStyle(.plain)

                Button(role: .destructive) {
                    NSApplication.shared.terminate(nil)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "power")
                            .font(.system(size: 11, weight: .semibold))
                        Text("退出 NotchNotch")
                            .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    }
                    .foregroundStyle(Color(red: 0.95, green: 0.35, blue: 0.35))
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color(red: 0.95, green: 0.35, blue: 0.35).opacity(0.12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(Color(red: 0.95, green: 0.35, blue: 0.35).opacity(0.25), lineWidth: 0.5)
                            )
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(JYLTheme.neutral900.opacity(0.7))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(JYLTheme.border.opacity(0.6), lineWidth: 0.8)
                )
        )
    }
}
