//
//  ClipboardCardView.swift
//  NotchNotch
//
//  Multi-item horizontal clipboard history carousel matching macOS native notch aesthetic.
//  Displays text previews, age badges, source application icons, and duplicate counters.
//

import AppKit
import SwiftUI

struct ClipboardCardView: View {

    var isActive: Bool = false

    @ObservedObject private var manager = ClipboardManager.shared
    @ObservedObject private var loc = LocalizationManager.shared
    @State private var copiedItemId: UUID? = nil

    private var displayItems: [ClipboardItem] {
        manager.items
    }

    var body: some View {
        Group {
            if displayItems.isEmpty {
                emptyState
            } else {
                carousel
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: isActive) { active in
            if active {
                manager.pollPasteboard()
            }
        }
    }

    // MARK: - Carousel

    private static let cardSpacing: CGFloat = 8
    /// Cards fully visible at once; anything beyond scrolls.
    private static let visibleColumns = 5
    /// How much of the next card shows when the row scrolls — the cue that it does.
    private static let peekWidth: CGFloat = 24

    private var carousel: some View {
        GeometryReader { geo in
            let cardWidth = Self.cardWidth(rowWidth: geo.size.width, count: displayItems.count)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Self.cardSpacing) {
                    ForEach(displayItems) { item in
                        ClipboardItemCard(item: item, width: cardWidth, isRecentlyCopied: copiedItemId == item.id) {
                            copy(item)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Cards stretch so the row is always filled edge to edge: up to five share
    /// the width evenly, and past five the sixth card peeks in at the trailing
    /// edge. A fixed card width left a black strip after the last card.
    private static func cardWidth(rowWidth: CGFloat, count: Int) -> CGFloat {
        let columns = CGFloat(max(1, min(count, visibleColumns)))
        let peek = count > visibleColumns ? cardSpacing + peekWidth : 0
        return max(0, (rowWidth - cardSpacing * (columns - 1) - peek) / columns)
    }

    private func copy(_ item: ClipboardItem) {
        manager.copyToPasteboard(item: item)
        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
            copiedItemId = item.id
        }
        NSSound(named: "Tink")?.play()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if copiedItemId == item.id {
                withAnimation(.easeOut(duration: 0.2)) {
                    copiedItemId = nil
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 24))
                .foregroundStyle(JYLTheme.neutral600)
            Text(L10n.tr(.clipboardEmptyTitle))
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .foregroundStyle(JYLTheme.textMuted)
            Text(loc.isChinese ? "从任意 App 复制文本即可自动记录" : "Copy text from any app to record history")
                .font(.system(size: 9.5, weight: .regular, design: .rounded))
                .foregroundStyle(JYLTheme.textMuted.opacity(0.8))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .jylCard()
    }
}

// MARK: - Item Card

private struct ClipboardItemCard: View {
    let item: ClipboardItem
    let width: CGFloat
    let isRecentlyCopied: Bool
    let onCopy: () -> Void

    @State private var isHovering = false

    private static let radius: CGFloat = 13

    var body: some View {
        Button(action: onCopy) {
            VStack(alignment: .leading, spacing: 0) {
                Text(item.text)
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(JYLTheme.textPrimary.opacity(0.92))
                    .lineLimit(5)
                    .lineSpacing(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                Spacer(minLength: 6)

                // Metadata lives in the footer so the preview gets the full card
                // width; an age pill in the top corner used to sit on the text.
                HStack(spacing: 5) {
                    sourceIcon

                    Text(item.ageString)
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(JYLTheme.textMuted)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    if item.copyCount > 1 {
                        Text("×\(item.copyCount)")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(JYLTheme.textSecondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                    }
                }
                .frame(height: 16)
            }
            .padding(.horizontal, 9)
            .padding(.top, 8)
            .padding(.bottom, 7)
            // Full row height: the row is exactly `expandedContentRowHeight`.
            .frame(width: width, height: NotchConfiguration.expandedContentRowHeight)
            .background(
                RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                    .fill(isHovering ? JYLTheme.neutral800 : JYLTheme.surfaceRaised)
                    .overlay(
                        RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                            .strokeBorder(JYLTheme.cardBorderGradient, lineWidth: 0.6)
                    )
            )
            .overlay { if isRecentlyCopied { copiedOverlay } }
            .contentShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        }
        .buttonStyle(ScaleButtonStyle(scale: 0.97))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
    }

    @ViewBuilder
    private var sourceIcon: some View {
        if let icon = item.appIcon {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
        } else if let name = item.appName, !name.isEmpty {
            Text(String(name.prefix(1)).uppercased())
                .font(.system(size: 8.5, weight: .bold, design: .rounded))
                .foregroundStyle(JYLTheme.textSecondary)
                .frame(width: 16, height: 16)
                .background(Circle().fill(JYLTheme.neutral700))
        }
    }

    private var copiedOverlay: some View {
        RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
            .fill(JYLTheme.surfaceRaised.opacity(0.88))
            .overlay(
                RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                    .strokeBorder(JYLTheme.success, lineWidth: 1.4)
            )
            .overlay(
                Image(systemName: "checkmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(JYLTheme.success)
            )
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }
}
