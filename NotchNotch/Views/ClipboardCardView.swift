//
//  ClipboardCardView.swift
//  NotchNotch
//
//  Pasteboard viewer card.
//

import SwiftUI
import AppKit

struct ClipboardCardView: View {

    var isActive: Bool = false
    @State private var clipboardText: String = ""
    @State private var copied: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "doc.on.doc.fill")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(JYLTheme.primary)
                Text("Clipboard")
                    .font(.system(size: 12.5, weight: .bold, design: .rounded))
                    .foregroundStyle(JYLTheme.textPrimary)
                Spacer()
                if !clipboardText.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        clipboardText = ""
                    } label: {
                        Text("Clear")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(JYLTheme.textMuted)
                    }
                    .buttonStyle(.plain)
                }
            }

            if clipboardText.isEmpty {
                VStack(spacing: 5) {
                    Spacer()
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 20))
                        .foregroundStyle(JYLTheme.neutral600)
                    Text("Clipboard is empty")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(JYLTheme.textMuted)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                Text(clipboardText)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(JYLTheme.textPrimary.opacity(0.92))
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(JYLTheme.surface)
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(JYLTheme.border, lineWidth: 0.5)
                            )
                    )

                HStack {
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(clipboardText, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            copied = false
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            Text(copied ? "Copied" : "Copy Again")
                        }
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(copied ? JYLTheme.success : JYLTheme.textPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(copied ? JYLTheme.successMuted : JYLTheme.neutral800))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .jylCard()
        .onAppear {
            readPasteboard()
        }
        .onChange(of: isActive) { active in
            if active {
                readPasteboard()
            }
        }
    }

    private func readPasteboard() {
        Task.detached(priority: .userInitiated) {
            let text = NSPasteboard.general.string(forType: .string) ?? ""
            await MainActor.run {
                if self.clipboardText != text {
                    self.clipboardText = text
                }
            }
        }
    }
}
