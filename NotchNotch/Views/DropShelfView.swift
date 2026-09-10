//
//  DropShelfView.swift
//  NotchNotch
//
//  The file staging shelf view.
//  Divided into two cards: Drop Files Here (~75%) and dedicated AirDrop tile (~25%).
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DropShelfView: View {

    @ObservedObject var shelf: ShelfController
    @State private var isAirDropTargeted: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            // Left Card: Main Drop Target (~75%)
            dropZoneCard
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Right Card: AirDrop Action Tile (~25%)
            airDropCard
                .frame(width: 115)
                .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Drop Zone Card

    private var dropZoneCard: some View {
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

    private var emptyDropTarget: some View {
        VStack(spacing: 7) {
            Image(systemName: "arrow.down.doc.fill")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(shelf.isTargeted ? JYLTheme.primary : Color.white.opacity(0.7))
                .scaleEffect(shelf.isTargeted ? 1.08 : 1.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: shelf.isTargeted)

            VStack(spacing: 2) {
                Text(shelf.isTargeted ? "Release to stage files" : "Drop Files Here")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(shelf.isTargeted ? JYLTheme.primary : JYLTheme.textPrimary)

                Text("Files kept for a day")
                    .font(.system(size: 10.5, weight: .regular, design: .rounded))
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
                    Image(systemName: "folder.fill")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(JYLTheme.primary)

                    Text("\(shelf.items.count) item\(shelf.items.count == 1 ? "" : "s") staged")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(JYLTheme.textSecondary)
                }

                Spacer()

                Button("Clear All") {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        shelf.clearAll()
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(JYLTheme.textMuted)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(JYLTheme.neutral800))
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(shelf.items) { item in
                        itemCard(item)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
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
                    .frame(width: 34, height: 34)
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 1.5)

                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        shelf.remove(id: item.id)
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(JYLTheme.textSecondary, JYLTheme.neutral900)
                }
                .buttonStyle(.plain)
                .offset(x: 3, y: -3)
            }

            Text(item.name)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(JYLTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 60)

            Text(item.formattedSize)
                .font(.system(size: 8, weight: .regular, design: .monospaced))
                .foregroundStyle(JYLTheme.textMuted)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(JYLTheme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
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
    }

    // MARK: - AirDrop Card

    private var airDropCard: some View {
        Button {
            triggerAirDrop()
        } label: {
            VStack(spacing: 8) {
                AirDropIconView(size: 32, isHighlighted: isAirDropTargeted)

                Text("AirDrop")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(isAirDropTargeted ? JYLTheme.primary : JYLTheme.textPrimary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .jylCard(
            isHighlighted: isAirDropTargeted,
            highlightGradient: LinearGradient(
                colors: [JYLTheme.info, JYLTheme.primary],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isAirDropTargeted) { providers in
            handleAirDropDrop(providers: providers)
        }
    }

    private func triggerAirDrop() {
        if !shelf.items.isEmpty {
            let urls = shelf.items.map { $0.url }
            if let service = NSSharingService(named: .sendViaAirDrop) {
                service.perform(withItems: urls)
                return
            }
        }

        // Open Finder AirDrop folder
        let airdropApp = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app/Contents/Applications/AirDrop.app")
        if FileManager.default.fileExists(atPath: airdropApp.path) {
            NSWorkspace.shared.open(airdropApp)
        } else if let finderAirDrop = URL(string: "finder:///AirDrop") {
            NSWorkspace.shared.open(finderAirDrop)
        }
    }

    private func handleAirDropDrop(providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { urls.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            if !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop) {
                service.perform(withItems: urls)
            }
        }
        return true
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var foundURLs: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { foundURLs.append(url) }
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

// MARK: - AirDrop Icon View

struct AirDropIconView: View {
    var size: CGFloat = 32
    var isHighlighted: Bool = false

    var body: some View {
        Canvas { context, canvasSize in
            let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            let color = isHighlighted ? Color(red: 0.96, green: 0.62, blue: 0.04) : Color.white.opacity(0.85)

            let dim = min(canvasSize.width, canvasSize.height)
            // Center solid circle
            let dotRadius = dim * 0.22
            let dotRect = CGRect(x: center.x - dotRadius, y: center.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
            context.fill(Path(ellipseIn: dotRect), with: .color(color))

            // Wave arcs on left and right
            let strokeStyle = StrokeStyle(lineWidth: 2.2, lineCap: .round)
            let r1 = dim * 0.38
            let r2 = dim * 0.52
            let arcSpan: CGFloat = 50.0

            // Left inner arc
            var leftInner = Path()
            leftInner.addArc(center: center, radius: r1,
                             startAngle: .degrees(180 - arcSpan),
                             endAngle: .degrees(180 + arcSpan),
                             clockwise: false)
            context.stroke(leftInner, with: .color(color), style: strokeStyle)

            // Left outer arc
            var leftOuter = Path()
            leftOuter.addArc(center: center, radius: r2,
                             startAngle: .degrees(180 - arcSpan),
                             endAngle: .degrees(180 + arcSpan),
                             clockwise: false)
            context.stroke(leftOuter, with: .color(color), style: strokeStyle)

            // Right inner arc
            var rightInner = Path()
            rightInner.addArc(center: center, radius: r1,
                              startAngle: .degrees(-arcSpan),
                              endAngle: .degrees(arcSpan),
                              clockwise: false)
            context.stroke(rightInner, with: .color(color), style: strokeStyle)

            // Right outer arc
            var rightOuter = Path()
            rightOuter.addArc(center: center, radius: r2,
                              startAngle: .degrees(-arcSpan),
                              endAngle: .degrees(arcSpan),
                              clockwise: false)
            context.stroke(rightOuter, with: .color(color), style: strokeStyle)
        }
        .frame(width: size, height: size)
    }
}
