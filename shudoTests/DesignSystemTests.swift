import Testing
import SwiftUI
import UIKit
@testable import shudo

struct DesignSystemTests {
    @Test func inkOnEveryFillMeetsWCAGAA() throws {
        let pairs: [(SwiftUI.Color, SwiftUI.Color)] = [
            (Design.Color.onEmber, Design.Color.ember),
            (Design.Color.onCream, Design.Color.cream),
            (Design.Color.onBubbleMe, Design.Color.bubbleMeTop),
            (Design.Color.onBubbleMe, Design.Color.bubbleMeBottom),
        ]
        for (ink, fill) in pairs {
            let ratio = try contrastRatio(foreground: UIColor(ink), background: UIColor(fill))
            #expect(ratio >= 4.5, "ink contrast was \(ratio)")
        }
    }

    @Test func readableTextTonesMeetWCAGAAOnEverySurface() throws {
        for foreground in [Design.Color.textPrimary, Design.Color.textSecondary, Design.Color.textTertiary] {
            for background in [Design.Color.canvas, Design.Color.surface1, Design.Color.surface2] {
                let ratio = try contrastRatio(
                    foreground: UIColor(foreground),
                    background: UIColor(background)
                )
                #expect(ratio >= 4.5, "text contrast was \(ratio)")
            }
        }
    }

    @Test func legacyTokenNamesResolveToTheNewPalette() {
        #expect(UIColor(Design.Color.ink) == UIColor(Design.Color.textPrimary))
        #expect(UIColor(Design.Color.muted) == UIColor(Design.Color.textSecondary))
        #expect(UIColor(Design.Color.accentPrimary) == UIColor(Design.Color.ember))
        #expect(UIColor(Design.Color.ringProtein) == UIColor(Design.Color.macroProtein))
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
