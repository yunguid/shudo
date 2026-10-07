import Testing
import UIKit
@testable import shudo

struct DesignSystemTests {
    @Test func emberFillsCarryDarkInkAboveWCAGAA() throws {
        for fill in [Design.Color.ember, Design.Color.bubbleMeTop, Design.Color.bubbleMeBottom] {
            let ratio = try contrastRatio(
                foreground: UIColor(Design.Color.onEmber),
                background: UIColor(fill)
            )
            #expect(ratio >= 4.5, "onEmber contrast was \(ratio)")
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

    @Test func radiusVocabularyIsStableAndMonotonic() {
        #expect(Design.Radius.tail < Design.Radius.chip)
        #expect(Design.Radius.chip < Design.Radius.control)
        #expect(Design.Radius.control < Design.Radius.bubble)
        #expect(Design.Radius.bubble < Design.Radius.card)
        #expect(Design.Radius.card < Design.Radius.cardLarge)
        #expect(Design.Radius.cardLarge < Design.Radius.sheet)
        #expect(Design.Radius.card == 22)
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
