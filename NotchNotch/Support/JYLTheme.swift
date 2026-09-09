import SwiftUI

// MARK: - JianyueLab Design Tokens
// Canonical source: @jianyuelab/tokens (packages/tokens/src/tokens.ts)

public enum JYLPalette {
    // Brand scale
    public static let brandStart = Color(hex: "#ef4136")
    public static let brandMid = Color(hex: "#f37235")
    public static let brandEnd = Color(hex: "#fbb040")
    public static let brandStrong = Color(hex: "#d6362a")
    public static let brandStronger = Color(hex: "#b62d22")

    // Neutral scale
    public static let neutral50 = Color(hex: "#fafafa")
    public static let neutral100 = Color(hex: "#f4f4f5")
    public static let neutral200 = Color(hex: "#e4e4e7")
    public static let neutral300 = Color(hex: "#d4d4d8")
    public static let neutral400 = Color(hex: "#a1a1aa")
    public static let neutral500 = Color(hex: "#71717a")
    public static let neutral600 = Color(hex: "#52525b")
    public static let neutral700 = Color(hex: "#3f3f46")
    public static let neutral800 = Color(hex: "#27272a")
    public static let neutral900 = Color(hex: "#18181b")
    public static let neutral950 = Color(hex: "#09090b")

    // Primary (Amber interactive accent — jianyuelab.co)
    public static let primary50 = Color(hex: "#fffbeb")
    public static let primary100 = Color(hex: "#fef3c7")
    public static let primary200 = Color(hex: "#fde68a")
    public static let primary300 = Color(hex: "#fcd34d")
    public static let primary400 = Color(hex: "#fbbf24")
    public static let primary500 = Color(hex: "#f59e0b")
    public static let primary600 = Color(hex: "#d97706")
    public static let primary700 = Color(hex: "#b45309")
    public static let primary800 = Color(hex: "#92400e")
    public static let primary900 = Color(hex: "#78350f")
    public static let primary950 = Color(hex: "#451a03")
}

public enum JYLTheme {
    // Surfaces & Backgrounds
    public static let surface = Color(hex: "#0f0f0f")
    public static let surfaceRaised = Color(hex: "#1a1a1a")
    public static let surfaceRaisedSecondary = Color(hex: "#27272a")

    // Typography & Content
    public static let textPrimary = Color(hex: "#fafafa")
    public static let textSecondary = Color(hex: "#a1a1aa")
    public static let textMuted = Color(hex: "#71717a")

    // Borders
    public static let border = Color(hex: "#27272a")
    public static let borderStrong = Color(hex: "#3f3f46")

    // Neutral aliases for convenient access
    public static let neutral50 = JYLPalette.neutral50
    public static let neutral100 = JYLPalette.neutral100
    public static let neutral200 = JYLPalette.neutral200
    public static let neutral300 = JYLPalette.neutral300
    public static let neutral400 = JYLPalette.neutral400
    public static let neutral500 = JYLPalette.neutral500
    public static let neutral600 = JYLPalette.neutral600
    public static let neutral700 = JYLPalette.neutral700
    public static let neutral800 = JYLPalette.neutral800
    public static let neutral900 = JYLPalette.neutral900
    public static let neutral950 = JYLPalette.neutral950

    // Primary Interactive Accent (Amber)
    public static let primary = JYLPalette.primary500
    public static let primaryHover = JYLPalette.primary600
    public static let primaryLight = JYLPalette.primary400
    public static let primaryMuted = Color(hex: "#f59e0b", opacity: 0.16)

    // Brand Identity
    public static let brandStart = JYLPalette.brandStart
    public static let brandMid = JYLPalette.brandMid
    public static let brandEnd = JYLPalette.brandEnd
    public static let brandMuted = Color(hex: "#ef4136", opacity: 0.16)

    public static let brandGradient = LinearGradient(
        colors: [brandStart, brandEnd],
        startPoint: .leading,
        endPoint: .trailing
    )

    public static let brandGradientDiagonal = LinearGradient(
        colors: [brandStart, brandEnd],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // Semantics (Dark theme calibrated)
    public static let success = Color(hex: "#4ade80")
    public static let successMuted = Color(hex: "#22c55e", opacity: 0.16)

    public static let warning = Color(hex: "#fbbf24")
    public static let warningMuted = Color(hex: "#f59e0b", opacity: 0.16)

    public static let error = Color(hex: "#f87171")
    public static let errorMuted = Color(hex: "#f87171", opacity: 0.16)

    public static let info = Color(hex: "#60a5fa")
    public static let infoMuted = Color(hex: "#60a5fa", opacity: 0.16)

    // Chart / Data-viz Series
    public static let chart1 = Color(hex: "#fbbf24")
    public static let chart2 = Color(hex: "#38bdf8")
    public static let chart3 = Color(hex: "#a78bfa")
    public static let chart4 = Color(hex: "#34d399")
    public static let chart5 = Color(hex: "#fb7185")

    // Subtle Card Border Gradient
    public static let cardBorderGradient = LinearGradient(
        colors: [borderStrong.opacity(0.85), border.opacity(0.55)],
        startPoint: .top,
        endPoint: .bottom
    )
}

// MARK: - Color Hex Initializer

extension Color {
    public init(hex: String, opacity: Double = 1.0) {
        let cleanHex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: cleanHex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch cleanHex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255.0,
            green: Double(g) / 255.0,
            blue: Double(b) / 255.0,
            opacity: opacity * (Double(a) / 255.0)
        )
    }
}

// MARK: - Card View Modifier

public struct JYLCardModifier: ViewModifier {
    public var cornerRadius: CGFloat
    public var isHighlighted: Bool
    public var highlightGradient: LinearGradient?

    public init(
        cornerRadius: CGFloat = 13,
        isHighlighted: Bool = false,
        highlightGradient: LinearGradient? = nil
    ) {
        self.cornerRadius = cornerRadius
        self.isHighlighted = isHighlighted
        self.highlightGradient = highlightGradient
    }

    public func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(JYLTheme.surfaceRaised)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(
                                isHighlighted
                                    ? (highlightGradient ?? LinearGradient(colors: [JYLTheme.primary, JYLTheme.primaryLight], startPoint: .top, endPoint: .bottom))
                                    : JYLTheme.cardBorderGradient,
                                lineWidth: isHighlighted ? 1.4 : 0.6
                            )
                    )
            )
    }
}

public extension View {
    func jylCard(
        cornerRadius: CGFloat = 13,
        isHighlighted: Bool = false,
        highlightGradient: LinearGradient? = nil
    ) -> some View {
        modifier(JYLCardModifier(cornerRadius: cornerRadius, isHighlighted: isHighlighted, highlightGradient: highlightGradient))
    }
}
