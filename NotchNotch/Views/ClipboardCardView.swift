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
    var searchQuery: String = ""

    @ObservedObject private var manager = ClipboardManager.shared
    @State private var copiedItemId: UUID? = nil

    private var displayItems: [ClipboardItem] {
        manager.filteredItems(query: searchQuery)
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

    private var carousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                ForEach(displayItems) { item in
                    clipboardItemCard(item)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Item Card

    private func clipboardItemCard(_ item: ClipboardItem) -> some View {
        let isRecentlyCopied = copiedItemId == item.id

        return Button {
            manager.copyToPasteboard(item: item)
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                copiedItemId = item.id
            }
            NSSound(named: "Tink")?.play()

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if copiedItemId == item.id {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        copiedItemId = nil
                    }
                }
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                // Card Base
                VStack(alignment: .leading, spacing: 0) {
                    // Text preview
                    Text(item.text)
                        .font(.system(size: 9.5, weight: .regular))
                        .foregroundStyle(JYLTheme.textPrimary.opacity(0.92))
                        .lineLimit(5)
                        .lineSpacing(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.top, 8)
                        .padding(.leading, 8)
                        .padding(.trailing, 34) // Give room for top-right age badge

                    Spacer(minLength: 4)

                    // Bottom badges: duplicate counter & source app icon
                    HStack(alignment: .bottom, spacing: 4) {
                        if item.copyCount > 1 {
                            Text("x\(item.copyCount)")
                                .font(.system(size: 8.5, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.white.opacity(0.95))
                                .padding(.horizontal, 4.5)
                                .padding(.vertical, 1.5)
                                .background(
                                    Capsule()
                                        .fill(Color.black.opacity(0.65))
                                )
                        }

                        Spacer(minLength: 0)

                        if let icon = item.appIcon {
                            Image(nsImage: icon)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 18, height: 18)
                                .clipShape(RoundedRectangle(cornerRadius: 4.5, style: .continuous))
                                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                        } else if let name = item.appName, !name.isEmpty {
                            Text(String(name.prefix(1)).uppercased())
                                .font(.system(size: 8.5, weight: .bold, design: .rounded))
                                .foregroundStyle(JYLTheme.textSecondary)
                                .frame(width: 17, height: 17)
                                .background(Circle().fill(JYLTheme.neutral800))
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.bottom, 7)
                }

                // Top-right Age Pill
                Text(item.ageString)
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.95))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.8)
                    .background(
                        Capsule()
                            .fill(Color.black.opacity(0.68))
                    )
                    .padding(5.5)

                // Flash feedback overlay on copy
                if isRecentlyCopied {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .strokeBorder(JYLTheme.success, lineWidth: 1.6)
                        .background(
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .fill(JYLTheme.successMuted.opacity(0.3))
                        )
                        .overlay(
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(JYLTheme.success)
                        )
                }
            }
            .frame(width: 106, height: 114)
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(Color(red: 0.13, green: 0.13, blue: 0.14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .strokeBorder(JYLTheme.borderStrong.opacity(0.4), lineWidth: 0.6)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 24))
                .foregroundStyle(JYLTheme.neutral600)
            Text(searchQuery.isEmpty ? "Clipboard is empty" : "No matches found")
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .foregroundStyle(JYLTheme.textMuted)
            Text(searchQuery.isEmpty ? "Copy text from any app to record history" : "Try a different search term")
                .font(.system(size: 9.5, weight: .regular, design: .rounded))
                .foregroundStyle(JYLTheme.textMuted.opacity(0.8))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .jylCard()
    }
}
