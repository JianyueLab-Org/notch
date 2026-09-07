//
//  NotchShape.swift
//  NotchNotch
//
//  The signature silhouette: square against the top of the screen, rounded at
//  the bottom, with a small *inverse* fillet at each top corner so the body
//  appears to melt into the bezel rather than sit on top of it.
//

import SwiftUI

nonisolated struct NotchShape: Shape {

    /// Radius of the two inverse fillets where the body meets the screen edge.
    var topRadius: CGFloat
    /// Radius of the two ordinary bottom corners.
    var bottomRadius: CGFloat

    /// Makes both radii animate alongside the frame change, so the corners
    /// tighten as the panel shrinks instead of snapping at the end.
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    /// NOTE: the path intentionally extends `topRadius` *outside* `rect` on both
    /// sides — that overhang is the flare. The parent must leave room for it;
    /// `NotchConfiguration.canvasHorizontalPadding` is what pays for it.
    func path(in rect: CGRect) -> Path {
        let top = max(0, min(topRadius, rect.height))
        let bottom = max(0, min(bottomRadius, min(rect.height, rect.width / 2)))

        var path = Path()

        // Start out on the screen edge, left of the body.
        path.move(to: CGPoint(x: rect.minX - top, y: rect.minY))
        // Inverse fillet curving down into the left wall.
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + top),
                          control: CGPoint(x: rect.minX, y: rect.minY))
        // Left wall.
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - bottom))
        path.addQuadCurve(to: CGPoint(x: rect.minX + bottom, y: rect.maxY),
                          control: CGPoint(x: rect.minX, y: rect.maxY))
        // Bottom edge.
        path.addLine(to: CGPoint(x: rect.maxX - bottom, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - bottom),
                          control: CGPoint(x: rect.maxX, y: rect.maxY))
        // Right wall.
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + top))
        path.addQuadCurve(to: CGPoint(x: rect.maxX + top, y: rect.minY),
                          control: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()

        return path
    }
}
