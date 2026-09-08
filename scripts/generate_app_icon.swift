#!/usr/bin/env swift

import AppKit
import CoreGraphics
import Foundation

func renderBaseIcon(size: CGFloat = 1024) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()

    guard let ctx = NSGraphicsContext.current?.cgContext else {
        img.unlockFocus()
        return img
    }

    // Canvas setup
    let margin = size * 0.1
    let bodyRect = CGRect(x: margin, y: margin, width: size - 2 * margin, height: size - 2 * margin)
    let cornerRadius = size * 0.2

    // Dark Obsidian body
    let bodyPath = CGPath(roundedRect: bodyRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    ctx.setFillColor(CGColor(red: 24/255, green: 24/255, blue: 28/255, alpha: 1.0))
    ctx.addPath(bodyPath)
    ctx.fillPath()

    // Inner border stroke
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.12))
    ctx.setLineWidth(4)
    ctx.addPath(bodyPath)
    ctx.strokePath()

    // Top specular highlight
    let highlightRect = CGRect(x: margin + 6, y: size - margin - size * 0.15, width: size - 2 * margin - 12, height: size * 0.14)
    let highlightPath = CGPath(roundedRect: highlightRect, cornerWidth: cornerRadius * 0.5, cornerHeight: cornerRadius * 0.5, transform: nil)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.05))
    ctx.addPath(highlightPath)
    ctx.fillPath()

    // Glow under notch
    let notchW = size * 0.38
    let notchH = size * 0.08
    let notchLeft = (size - notchW) / 2
    let notchY = size - margin - notchH - 8 // AppKit coordinate: top is high Y

    ctx.saveGState()
    let glowRect = CGRect(x: notchLeft - 30, y: notchY - 40, width: notchW + 60, height: notchH + 60)
    ctx.setFillColor(CGColor(red: 56/255, green: 189/255, blue: 248/255, alpha: 0.45)) // cyan
    ctx.fillEllipse(in: glowRect)
    let glowRect2 = CGRect(x: notchLeft + 20, y: notchY - 30, width: notchW - 40, height: notchH + 40)
    ctx.setFillColor(CGColor(red: 168/255, green: 85/255, blue: 247/255, alpha: 0.5)) // purple
    ctx.fillEllipse(in: glowRect2)
    ctx.restoreGState()

    // Notch silhouette: solid black pill attached to top border
    let notchRect = CGRect(x: notchLeft, y: notchY, width: notchW, height: notchH)
    let notchPath = CGPath(roundedRect: notchRect, cornerWidth: notchH * 0.45, cornerHeight: notchH * 0.45, transform: nil)
    ctx.setFillColor(CGColor(red: 10/255, green: 10/255, blue: 12/255, alpha: 1.0))
    ctx.addPath(notchPath)
    ctx.fillPath()

    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.18))
    ctx.setLineWidth(2)
    ctx.addPath(notchPath)
    ctx.strokePath()

    // Camera dot
    let camRect = CGRect(x: size / 2 - 5, y: notchY + notchH / 2 - 5, width: 10, height: 10)
    ctx.setFillColor(CGColor(red: 20/255, green: 24/255, blue: 38/255, alpha: 1.0))
    ctx.fillEllipse(in: camRect)
    ctx.setStrokeColor(CGColor(red: 56/255, green: 189/255, blue: 248/255, alpha: 0.4))
    ctx.setLineWidth(1)
    ctx.strokeEllipse(in: camRect)

    // Music wave bars in the center
    let centerY = size * 0.42
    for i in 0..<11 {
        let bx = size * 0.32 + CGFloat(i) * size * 0.036
        let h = sin(Double(i) * 0.7) * 45 + 55
        let barRect = CGRect(x: bx, y: centerY - CGFloat(h) / 2, width: 12, height: CGFloat(h))
        let barPath = CGPath(roundedRect: barRect, cornerWidth: 5, cornerHeight: 5, transform: nil)
        ctx.setFillColor(CGColor(red: 240/255, green: 240/255, blue: 250/255, alpha: 0.85))
        ctx.addPath(barPath)
        ctx.fillPath()
    }

    img.unlockFocus()
    return img
}

func savePNG(image: NSImage, targetSize: Int, to url: URL) {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: targetSize,
        pixelsHigh: targetSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: targetSize, height: targetSize),
               from: NSRect(origin: .zero, size: image.size),
               operation: .copy,
               fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()

    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: url)
    }
}

let targetDir = URL(fileURLWithPath: "NotchNotch/Assets.xcassets/AppIcon.appiconset")
try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

let baseImage = renderBaseIcon(size: 1024)

let specs: [(size: Int, scale: Int, filename: String)] = [
    (16, 1, "icon_16x16.png"),
    (16, 2, "icon_16x16@2x.png"),
    (32, 1, "icon_32x32.png"),
    (32, 2, "icon_32x32@2x.png"),
    (128, 1, "icon_128x128.png"),
    (128, 2, "icon_128x128@2x.png"),
    (256, 1, "icon_256x256.png"),
    (256, 2, "icon_256x256@2x.png"),
    (512, 1, "icon_512x512.png"),
    (512, 2, "icon_512x512@2x.png"),
]

var imagesJSON: [[String: String]] = []

for spec in specs {
    let px = spec.size * spec.scale
    let fileURL = targetDir.appendingPathComponent(spec.filename)
    savePNG(image: baseImage, targetSize: px, to: fileURL)
    imagesJSON.append([
        "size": "\(spec.size)x\(spec.size)",
        "idiom": "mac",
        "filename": spec.filename,
        "scale": "\(spec.scale)x"
    ])
}

let contents: [String: Any] = [
    "images": imagesJSON,
    "info": [
        "author": "xcode",
        "version": 1
    ]
]

if let jsonData = try? JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted]) {
    try? jsonData.write(to: targetDir.appendingPathComponent("Contents.json"))
}

print("Successfully generated all AppIcon assets via Swift CoreGraphics.")
