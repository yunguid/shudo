import Testing
import UIKit
@testable import shudo

struct DesignSystemTests {
    @Test func callToActionGradientMeetsWCAGAAForWhiteText() throws {
        for theme in AppTheme.allCases {
            for color in [theme.palette.ctaPrimary, theme.palette.ctaSecondary] {
                let ratio = try contrastRatio(
                    foreground: .white,
                    background: UIColor(color)
                )
                #expect(ratio >= 4.5, "\(theme.title) CTA contrast was \(ratio)")
            }
        }
    }

    @Test func secondaryCopyMeetsWCAGAAOnAppSurfaces() throws {
        for theme in AppTheme.allCases {
            let foreground = UIColor(theme.palette.muted)
            for background in [theme.palette.paper, theme.palette.elevated] {
                let ratio = try contrastRatio(
                    foreground: foreground,
                    background: UIColor(background)
                )
                #expect(ratio >= 4.5, "\(theme.title) secondary contrast was \(ratio)")
            }
        }
    }

    @Test func themeSelectionHasAStableGrooveboxDefault() {
        #expect(AppTheme.defaultTheme == .groovebox)
        #expect(Set(AppTheme.allCases.map(\.rawValue)).count == AppTheme.allCases.count)
    }

    private func contrastRatio(
        foreground: UIColor,
        background: UIColor
    ) throws -> Double {
        let foregroundLuminance = try relativeLuminance(foreground)
        let backgroundLuminance = try relativeLuminance(background)
        let lighter = max(foregroundLuminance, backgroundLuminance)
        let darker = min(foregroundLuminance, backgroundLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func relativeLuminance(_ color: UIColor) throws -> Double {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        try #require(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha))

        func linearized(_ component: CGFloat) -> Double {
            let value = Double(component)
            if value <= 0.04045 { return value / 12.92 }
            return pow((value + 0.055) / 1.055, 2.4)
        }

        return 0.2126 * linearized(red)
            + 0.7152 * linearized(green)
            + 0.0722 * linearized(blue)
    }
}
