import SwiftUI

// MARK: - Shudo 2.0 design system: "Chalk · Iron · Ember"
//
// The palette is sampled from the app icon (amber → honey → cream pads on
// warm black) so the inside of the app matches the outside. Dark only.

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

enum Design {
    enum Color {
        // Iron: surfaces, warm-neutral blacks (icon background is #181512).
        static let canvas = SwiftUI.Color(hex: 0x0C0B0A)
        static let surface1 = SwiftUI.Color(hex: 0x161412)
        static let surface2 = SwiftUI.Color(hex: 0x201D1A)
        static let surface3 = SwiftUI.Color(hex: 0x2B2723)
        static let hairline = SwiftUI.Color(hex: 0xF3ECE0, alpha: 0.10)
        static let strokeStrong = SwiftUI.Color(hex: 0xF3ECE0, alpha: 0.18)

        // Chalk: text.
        static let textPrimary = SwiftUI.Color(hex: 0xF3ECE0)
        static let textSecondary = SwiftUI.Color(hex: 0xADA597)
        /// ≥4.7:1 on every surface — the faintest tone allowed for readable text.
        static let textTertiary = SwiftUI.Color(hex: 0x908878)
        static let textDisabled = SwiftUI.Color(hex: 0x4B463F)

        // Ember: brand. Icon pads: #DE9D43 / #FAD597 / #F9E4CA.
        static let ember = SwiftUI.Color(hex: 0xEFA04A)
        static let emberDeep = SwiftUI.Color(hex: 0xC9782A)
        static let honey = SwiftUI.Color(hex: 0xF7D39A)
        static let cream = SwiftUI.Color(hex: 0xFAE7CE)
        /// Ink on ember fills (8.7:1).
        static let onEmber = SwiftUI.Color(hex: 0x1B1108)

        // Macros: calories + protein are the hero pair, carbs/fat secondary.
        static let macroKcal = cream
        static let macroProtein = ember
        static let macroCarbs = SwiftUI.Color(hex: 0x86B8D8)
        static let macroFat = SwiftUI.Color(hex: 0xB7C77F)

        // Signals. Gaining toward a bulk goal is progress (ember), never a warning.
        static let positive = SwiftUI.Color(hex: 0x7FD1A8)
        static let warning = honey
        static let danger = SwiftUI.Color(hex: 0xF2665A)

        // Thread.
        static let bubbleCoach = surface2
        static let bubbleMeTop = SwiftUI.Color(hex: 0xF3AE5E)
        static let bubbleMeBottom = SwiftUI.Color(hex: 0xE38F38)
        static var bubbleMe: LinearGradient {
            LinearGradient(colors: [bubbleMeTop, bubbleMeBottom], startPoint: .top, endPoint: .bottom)
        }
        static var emberFill: LinearGradient {
            LinearGradient(colors: [honey, ember, emberDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
        }

        // Heatmap ramp: the icon's pads, dark to bright.
        static let heatmapRamp: [SwiftUI.Color] = [
            surface3, SwiftUI.Color(hex: 0x6B4520), emberDeep, SwiftUI.Color(hex: 0xDE9D43), honey,
        ]

        // MARK: Legacy names (1.x views). New code uses the tokens above.
        static var paper: SwiftUI.Color { canvas }
        static var elevated: SwiftUI.Color { surface1 }
        static var glassFill: SwiftUI.Color { surface1 }
        static var ink: SwiftUI.Color { textPrimary }
        static var muted: SwiftUI.Color { textSecondary }
        static var subtle: SwiftUI.Color { textTertiary }
        static var rule: SwiftUI.Color { hairline }
        static var heatmapEmpty: SwiftUI.Color { surface3 }
        static var heatmapBorder: SwiftUI.Color { strokeStrong }
        static var accentPrimary: SwiftUI.Color { ember }
        static var accentSecondary: SwiftUI.Color { honey }
        static var ctaPrimary: SwiftUI.Color { ember }
        static var ctaSecondary: SwiftUI.Color { emberDeep }
        static var success: SwiftUI.Color { positive }
        static var ringProtein: SwiftUI.Color { macroProtein }
        static var ringCarb: SwiftUI.Color { macroCarbs }
        static var ringFat: SwiftUI.Color { macroFat }
    }

    enum Typeface {
        /// Every number in the app: SF Pro Rounded; add `.monospacedDigit()` at the call site.
        static func numeral(_ style: SwiftUI.Font.TextStyle, weight: SwiftUI.Font.Weight = .semibold) -> SwiftUI.Font {
            .system(style, design: .rounded, weight: weight)
        }
        /// Plate-stamp labels (GAME PLAN, NEARBY, KCAL LEFT). Use `eyebrowStyle()`.
        static let eyebrow = SwiftUI.Font.system(.caption2, weight: .heavy).width(.expanded)
        static let stamp = SwiftUI.Font.system(.subheadline, weight: .heavy).width(.expanded)
        static let screenTitle = SwiftUI.Font.system(.title2, weight: .heavy).width(.expanded)
        static let bubble = SwiftUI.Font.body
        static let cardTitle = SwiftUI.Font.headline
        static let meta = SwiftUI.Font.caption2.weight(.medium)
    }

    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let gutter: CGFloat = 20
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let tail: CGFloat = 6
        static let chip: CGFloat = 10
        static let control: CGFloat = 16
        static let bubble: CGFloat = 20
        /// Thread cards and content cards.
        static let card: CGFloat = 22
        /// Large hero cards (day header, body hero).
        static let cardLarge: CGFloat = 26
        static let sheet: CGFloat = 28

        // Legacy names (1.x views).
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let panel: CGFloat = 18
        static let xl: CGFloat = 20
        static let hero: CGFloat = 24
    }

    enum Stroke {
        static let hairline: CGFloat = 0.5
    }

    enum Motion {
        static let snap = Animation.snappy(duration: 0.25)
        static let settle = Animation.smooth(duration: 0.4)
        static let arrive = Animation.bouncy(duration: 0.45, extraBounce: 0.08)
        static let ring = Animation.spring(response: 0.9, dampingFraction: 0.8)
        static func gated(_ animation: Animation, reduceMotion: Bool) -> Animation? {
            reduceMotion ? nil : animation
        }
    }
}

// MARK: - Materials

extension View {
    /// Liquid Glass for floating chrome only (headers, capture bar, pills).
    /// Content cards stay opaque (`cardSurface`).
    func chromeGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
    }

    func cardSurface(radius: CGFloat = Design.Radius.card) -> some View {
        background(
            Design.Color.surface1,
            in: RoundedRectangle(cornerRadius: radius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(Design.Color.hairline, lineWidth: Design.Stroke.hairline)
        )
    }

    func eyebrowStyle(_ color: Color = Design.Color.textTertiary) -> some View {
        font(Design.Typeface.eyebrow)
            .tracking(1.1)
            .textCase(.uppercase)
            .foregroundStyle(color)
    }
}

/// One consistent hairline rule; Divider ignores tint and renders the system
/// separator color, so lists use this instead.
struct HairlineRule: View {
    var body: some View {
        Rectangle()
            .fill(Design.Color.hairline)
            .frame(height: Design.Stroke.hairline)
    }
}

private struct ShimmerModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceMotion {
            content.opacity(0.72)
        } else {
            content
                .overlay {
                    GeometryReader { geometry in
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.38), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .rotationEffect(.degrees(18))
                        .offset(x: phase * geometry.size.width * 1.8)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
                .onAppear {
                    withAnimation(.linear(duration: 1.25).repeatForever(autoreverses: false)) {
                        phase = 1
                    }
                }
        }
    }
}

extension View {
    func shimmering() -> some View { modifier(ShimmerModifier()) }
}

// MARK: - Button Styles

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Design.Color.onEmber)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(
                Design.Color.emberFill,
                in: RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
            )
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Design.Color.textPrimary)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(
                Design.Color.surface3,
                in: RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
            )
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
    }
}
