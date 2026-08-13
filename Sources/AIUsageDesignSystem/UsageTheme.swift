import AIUsageCore
import SwiftUI

public enum UsageTheme {
    public static let stage = Color(red: 22 / 255, green: 22 / 255, blue: 24 / 255)
    public static let panelTop = Color(red: 13 / 255, green: 14 / 255, blue: 16 / 255)
    public static let panelBottom = Color(red: 7 / 255, green: 7 / 255, blue: 8 / 255)
    public static let primaryText = Color(red: 246 / 255, green: 246 / 255, blue: 248 / 255)
    public static let secondaryText = Color(red: 194 / 255, green: 196 / 255, blue: 202 / 255)
    public static let weeklyText = Color(red: 199 / 255, green: 200 / 255, blue: 205 / 255)
    public static let metaText = Color(red: 154 / 255, green: 156 / 255, blue: 162 / 255)
    public static let tertiaryText = Color(red: 124 / 255, green: 126 / 255, blue: 134 / 255)
    public static let mutedText = Color(red: 93 / 255, green: 95 / 255, blue: 102 / 255)
    public static let green = Color(red: 62 / 255, green: 207 / 255, blue: 142 / 255)
    public static let amber = Color(red: 245 / 255, green: 196 / 255, blue: 81 / 255)
    public static let red = Color(red: 222 / 255, green: 76 / 255, blue: 74 / 255)
    public static let mock = Color(red: 138 / 255, green: 124 / 255, blue: 255 / 255)
    public static let claude = amber
    public static let codex = green
    public static let hairline = Color.white.opacity(0.06)
    public static let track = Color.white.opacity(0.07)

    public static let buttonFill = Color.white.opacity(0.045)
    public static let buttonBorder = Color.white.opacity(0.08)

    public static var panelGradient: RadialGradient {
        RadialGradient(
            colors: [panelTop, panelBottom],
            center: UnitPoint(x: 0.5, y: -0.08),
            startRadius: 0,
            endRadius: 430
        )
    }

    public static func provider(_ provider: UsageProviderID) -> Color {
        switch provider {
        case .claude: claude
        case .codex: codex
        }
    }

    public static func severity(_ severity: UsageSeverity) -> Color {
        switch severity {
        case .normal: green
        case .warning: amber
        case .critical, .unavailable: red
        }
    }
}

public extension View {
    func usagePanel(cornerRadius: CGFloat = 22) -> some View {
        background(UsageTheme.panelGradient)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(UsageTheme.hairline, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.58), radius: 28, y: 16)
    }
}
