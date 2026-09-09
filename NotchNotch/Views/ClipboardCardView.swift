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
                    .foregroundStyle(Color.accentColor)
                Text("Clipboard")
                    .font(.system(size: 12.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                if !clipboardText.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        clipboardText = ""
                    } label: {
                        Text("Clear")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }
            }

            if clipboardText.isEmpty {
                VStack(spacing: 5) {
                    Spacer()
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.3))
                    Text("Clipboard is empty")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                Text(clipboardText)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.white.opacity(0.04))
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
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.white.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color(white: 0.11))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.15), Color.white.opacity(0.04)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.5
                        )
                )
        )
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
