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
        VStack(spacing: 8) {
            if shelf.items.isEmpty {
                emptyDropTarget
            } else {
                itemsContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $shelf.isTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    // MARK: - Subviews

    private var emptyDropTarget: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    shelf.isTargeted ? Color.accentColor : Color.white.opacity(0.18),
                    style: StrokeStyle(lineWidth: shelf.isTargeted ? 2 : 1.5, dash: shelf.isTargeted ? [] : [6, 4])
                )
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(shelf.isTargeted ? Color.accentColor.opacity(0.12) : Color.white.opacity(0.04))
                )

            VStack(spacing: 6) {
                Image(systemName: shelf.isTargeted ? "arrow.down.doc.fill" : "tray.and.arrow.down")
                    .font(.system(size: 24))
                    .foregroundStyle(shelf.isTargeted ? Color.accentColor : .white.opacity(0.4))
                Text(shelf.isTargeted ? "Release to stage files" : "Drop files here to hold")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(shelf.isTargeted ? 0.95 : 0.6))
                Text("Drag out anytime to transfer across apps")
                    .font(.system(size: 10, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private var itemsContent: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(shelf.items) { item in
                        itemCard(item)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }

            HStack {
                Text("\(shelf.items.count) item\(shelf.items.count == 1 ? "" : "s") staged")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                Button("Clear All") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        shelf.clearAll()
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(.white.opacity(0.12)))
            }
            .padding(.horizontal, 4)
        }
    }

    private func itemCard(_ item: ShelfItem) -> some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: item.icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 40, height: 40)
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 2)

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        shelf.remove(id: item.id)
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.75), .black.opacity(0.6))
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
            }

            Text(item.name)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 72)

            Text(item.formattedSize)
                .font(.system(size: 8, weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.08))
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
