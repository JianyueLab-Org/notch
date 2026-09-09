//
//  DropShelfView.swift
//  NotchNotch
//
//  The file staging shelf view.
//  Renders empty state, drop target highlight, file card carousel, and drag-out support.
//

import SwiftUI
import UniformTypeIdentifiers

struct DropShelfView: View {

    @ObservedObject var shelf: ShelfController

    var body: some View {
        ZStack {
            if shelf.items.isEmpty {
                emptyDropTarget
            } else {
                itemsContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .jylCard(
            isHighlighted: shelf.isTargeted,
            highlightGradient: LinearGradient(
                colors: [JYLTheme.primary, JYLTheme.primaryLight],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $shelf.isTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    // MARK: - Subviews

    private var emptyDropTarget: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(shelf.isTargeted ? JYLTheme.primaryMuted : JYLTheme.neutral800)
                    .frame(width: 36, height: 36)

                Image(systemName: shelf.isTargeted ? "arrow.down.doc.fill" : "tray.and.arrow.down")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(shelf.isTargeted ? JYLTheme.primary : JYLTheme.textSecondary)
            }
            .scaleEffect(shelf.isTargeted ? 1.08 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: shelf.isTargeted)

            VStack(spacing: 2.5) {
                Text(shelf.isTargeted ? "Release to stage files" : "Drop files here to hold")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(shelf.isTargeted ? JYLTheme.primary : JYLTheme.textPrimary)

                Text("Drag out anytime to transfer across apps")
                    .font(.system(size: 10, weight: .regular, design: .rounded))
                    .foregroundStyle(JYLTheme.textMuted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(12)
    }

    private var itemsContent: some View {
        VStack(spacing: 6) {
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: "tray.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(JYLTheme.primary)

                    Text("\(shelf.items.count) item\(shelf.items.count == 1 ? "" : "s") staged")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(JYLTheme.textSecondary)
                }

                Spacer()

                Button("Clear All") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        shelf.clearAll()
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundStyle(JYLTheme.textSecondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(Capsule().fill(JYLTheme.neutral800))
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(shelf.items) { item in
                        itemCard(item)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func itemCard(_ item: ShelfItem) -> some View {
        VStack(spacing: 3) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: item.icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 36, height: 36)
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 2)

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        shelf.remove(id: item.id)
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(JYLTheme.textSecondary, JYLTheme.neutral900)
                }
                .buttonStyle(.plain)
                .offset(x: 3, y: -3)
            }

            Text(item.name)
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundStyle(JYLTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 64)

            Text(item.formattedSize)
                .font(.system(size: 8, weight: .regular, design: .monospaced))
                .foregroundStyle(JYLTheme.textMuted)
        }
        .padding(7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(JYLTheme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(JYLTheme.border, lineWidth: 0.5)
                )
        )
        .contentShape(Rectangle())
        .onDrag {
            NSItemProvider(contentsOf: item.url) ?? NSItemProvider()
        }
        .onTapGesture(count: 2) {
            shelf.open(item: item)
        }
        .contextMenu {
            Button("Open") { shelf.open(item: item) }
            Button("Reveal in Finder") { shelf.revealInFinder(item: item) }
            Divider()
            Button("Remove") { shelf.remove(id: item.id) }
        }
    }

    // MARK: - Drop Handling

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var foundURLs: [URL] = []
        let group = DispatchGroup()

        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    foundURLs.append(url)
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            if !foundURLs.isEmpty {
                self.shelf.addURLs(foundURLs)
            }
        }

        return true
    }
}
