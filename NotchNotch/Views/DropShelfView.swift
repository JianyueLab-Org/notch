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
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color(white: 0.11))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(
                            shelf.isTargeted
                                ? LinearGradient(
                                    colors: [Color.accentColor, Color.accentColor.opacity(0.6)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                                : LinearGradient(
                                    colors: [Color.white.opacity(0.15), Color.white.opacity(0.04)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                            lineWidth: shelf.isTargeted ? 1.5 : 0.5
                        )
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
                    .fill(shelf.isTargeted ? Color.accentColor.opacity(0.22) : Color.white.opacity(0.06))
                    .frame(width: 36, height: 36)

                Image(systemName: shelf.isTargeted ? "arrow.down.doc.fill" : "tray.and.arrow.down")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(shelf.isTargeted ? Color.accentColor : Color.white.opacity(0.65))
            }
            .scaleEffect(shelf.isTargeted ? 1.08 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: shelf.isTargeted)

            VStack(spacing: 2.5) {
                Text(shelf.isTargeted ? "Release to stage files" : "Drop files here to hold")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(shelf.isTargeted ? 1.0 : 0.88))

                Text("Drag out anytime to transfer across apps")
                    .font(.system(size: 10, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
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
                        .foregroundStyle(Color.accentColor)

                    Text("\(shelf.items.count) item\(shelf.items.count == 1 ? "" : "s") staged")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                }

                Spacer()

                Button("Clear All") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        shelf.clearAll()
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(Capsule().fill(Color.white.opacity(0.12)))
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
                        .foregroundStyle(.white.opacity(0.75), .black.opacity(0.6))
                }
                .buttonStyle(.plain)
                .offset(x: 3, y: -3)
            }

            Text(item.name)
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 64)

            Text(item.formattedSize)
                .font(.system(size: 8, weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
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
