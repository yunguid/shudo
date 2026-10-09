import SwiftUI
import UIKit

// MARK: - Shudo design system: "Sumi · Hinoki · Pernambuco"
//
// A dark wood room. The canvas is sumi ink warmed toward walnut; text and
// quiet fills are hinoki and oak; the one accent is Pernambuco — the
// orange-red heartwood violin bows are cut from (and 朱, shu, the vermilion
// in Shudo's name). Material and colour temperature, never fake grain.
//
// Restraint rules:
// - One accent. Pernambuco marks what matters (protein, the live state, your
//   own words); everything else is cream, oak or ink.
// - Space before lines. Group with spacing first, a surface second, a rule
//   last. Cards carry no border, only a faint top-lit edge.
// - One typeface. Merriweather for everything, sentence case only — no
//   uppercase labels. Small quiet eyebrows, and fewer of them.
// - Motion slides home like a shoji door: weighted springs, no bounce,
//   opacity-only under Reduce Motion.

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
        // Sumi / walnut: surfaces, each step a little more lamp-lit.
        static let canvas = SwiftUI.Color(hex: 0x0E0B09)
        static let surface1 = SwiftUI.Color(hex: 0x17120F)
        static let surface2 = SwiftUI.Color(hex: 0x211A16)
        static let surface3 = SwiftUI.Color(hex: 0x2C231E)
        static let hairline = SwiftUI.Color(hex: 0xF1E7D8, alpha: 0.08)
        static let strokeStrong = SwiftUI.Color(hex: 0xF1E7D8, alpha: 0.16)

        // Hinoki / oak: text.
        static let textPrimary = SwiftUI.Color(hex: 0xF1E7D8)
        static let textSecondary = SwiftUI.Color(hex: 0xB8A891)
        /// ≥4.9:1 on canvas, surface1 and surface2 — the faintest tone allowed
        /// for readable text.
        static let textTertiary = SwiftUI.Color(hex: 0x978770)
        static let textDisabled = SwiftUI.Color(hex: 0x4D433A)

        // Pernambuco: the single accent, and its heartwood.
        static let pernambuco = SwiftUI.Color(hex: 0xD26842)
        static let heartwood = SwiftUI.Color(hex: 0x9A3D22)
        /// Aged oak — the warm secondary (warnings, streaks, soft highlights).
        static let oak = SwiftUI.Color(hex: 0xE3BF8C)
        /// Hinoki cream — primary fills, the capture dial's glass, kcal.
        static let hinoki = SwiftUI.Color(hex: 0xF4E6D0)
        /// Sumi ink for text on Pernambuco or hinoki fills (≥5.6:1).
        static let sumi = SwiftUI.Color(hex: 0x1A0E08)

        // Long-standing names for the same woods; most views use these.
        static var ember: SwiftUI.Color { pernambuco }
        static var emberDeep: SwiftUI.Color { heartwood }
        static var honey: SwiftUI.Color { oak }
        static var cream: SwiftUI.Color { hinoki }
        static var onEmber: SwiftUI.Color { sumi }
        static var onCream: SwiftUI.Color { sumi }

        // Macros: calories + protein are the hero pair, carbs/fat recede into
        // natural pigments (aizome slate, matcha).
        static let macroKcal = hinoki
        static let macroProtein = pernambuco
        static let macroCarbs = SwiftUI.Color(hex: 0x8FA9BA)
        static let macroFat = SwiftUI.Color(hex: 0xAEB781)

        // Signals. Gaining toward a bulk goal is progress (accent), never a
        // warning. Danger leans crimson so it never reads as the accent.
        static let positive = SwiftUI.Color(hex: 0x93C29C)
        static var warning: SwiftUI.Color { oak }
        static let danger = SwiftUI.Color(hex: 0xE8505F)

        // Thread: Shudo speaks from walnut, you speak in lacquered heartwood.
        static let bubbleCoach = surface2
        static let bubbleMeTop = SwiftUI.Color(hex: 0x9E4329)
        static let bubbleMeBottom = SwiftUI.Color(hex: 0x8A3720)
        static var onBubbleMe: SwiftUI.Color { textPrimary }
        static var bubbleMe: LinearGradient {
            LinearGradient(colors: [bubbleMeTop, bubbleMeBottom], startPoint: .top, endPoint: .bottom)
        }
        /// A Pernambuco fill with the faintest lacquer sheen (accent CTAs, the
        /// record button). Ink on it is `onEmber`.
        static var emberFill: LinearGradient {
            LinearGradient(
                colors: [SwiftUI.Color(hex: 0xDB7550), pernambuco],
                startPoint: .top,
                endPoint: .bottom
            )
        }

        // Heatmap ramp: bare wood to heartwood to Pernambuco to oak.
        static let heatmapRamp: [SwiftUI.Color] = [
            surface3, SwiftUI.Color(hex: 0x5A2818), heartwood, pernambuco, oak,
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

    /// One typeface for the whole app: Merriweather (bundled, SIL OFL —
    /// shudo/Fonts). Every piece of text goes through here so the app reads
    /// in a single voice. Sentence case everywhere: no uppercase labels.
    enum Typeface {
        static let family = "Merriweather"

        /// The base text API. Sizes sit a touch under SF's because
        /// Merriweather's tall x-height reads larger; `relativeTo` keeps
        /// Dynamic Type scaling.
        static func text(_ style: SwiftUI.Font.TextStyle = .body, weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font {
            .custom(faceName(weight), size: pointSize(style), relativeTo: style)
        }
        /// Screen and hero headlines.
        static func display(_ style: SwiftUI.Font.TextStyle = .largeTitle, weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font {
            text(style, weight: weight)
        }
        /// The one big number on a screen (kcal left, body weight).
        static func figure(_ style: SwiftUI.Font.TextStyle = .largeTitle, weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font {
            text(style, weight: weight).monospacedDigit()
        }
        /// Every other number, with tabular figures so columns line up.
        static func numeral(_ style: SwiftUI.Font.TextStyle, weight: SwiftUI.Font.Weight = .medium) -> SwiftUI.Font {
            text(style, weight: weight).monospacedDigit()
        }
        /// Small section labels, sentence case. Use `eyebrowStyle()`, and only
        /// when spacing alone can't say where a section starts.
        static let eyebrow = text(.caption, weight: .semibold)
        static let stamp = text(.subheadline, weight: .semibold)
        static let screenTitle = text(.title2, weight: .medium)
        static let bubble = text(.body)
        static let cardTitle = text(.headline, weight: .semibold)
        static let meta = text(.caption2, weight: .medium)

        /// The PostScript name of the variable font's named instance.
        static func faceName(_ weight: SwiftUI.Font.Weight) -> String {
            switch weight {
            case .ultraLight, .thin, .light: "Merriweather-Light"
            case .medium: "Merriweather-Medium"
            case .semibold: "Merriweather-SemiBold"
            case .bold: "Merriweather-Bold"
            case .heavy: "Merriweather-ExtraBold"
            case .black: "Merriweather-Black"
            default: "Merriweather-Regular"
            }
        }

        static func pointSize(_ style: SwiftUI.Font.TextStyle) -> CGFloat {
            switch style {
            case .largeTitle: 32
            case .title: 26
            case .title2: 21
            case .title3: 19
            case .headline: 16
            case .callout: 15
            case .subheadline: 14
            case .footnote: 12.5
            case .caption: 11.5
            case .caption2: 10.5
            default: 16
            }
        }

        /// The same face for UIKit chrome (navigation titles, bar buttons).
        static func uiFont(_ style: UIFont.TextStyle, weight: SwiftUI.Font.Weight = .regular, size: CGFloat) -> UIFont {
            let base = UIFont(name: faceName(weight), size: size) ?? .systemFont(ofSize: size)
            return UIFontMetrics(forTextStyle: style).scaledFont(for: base)
        }

        /// Points UIKit-drawn chrome at Merriweather. Call once at launch.
        static func installAppearance() {
            let navigation = UINavigationBar.appearance()
            navigation.titleTextAttributes = [.font: uiFont(.headline, weight: .semibold, size: 16)]
            navigation.largeTitleTextAttributes = [.font: uiFont(.largeTitle, size: 32)]
            let barButton = UIBarButtonItem.appearance()
            for state: UIControl.State in [.normal, .highlighted, .disabled] {
                barButton.setTitleTextAttributes([.font: uiFont(.body, weight: .medium, size: 16)], for: state)
            }
            UITabBarItem.appearance().setTitleTextAttributes(
                [.font: uiFont(.caption2, weight: .medium, size: 10)], for: .normal
            )
            UISegmentedControl.appearance().setTitleTextAttributes(
                [.font: uiFont(.subheadline, weight: .medium, size: 13)], for: .normal
            )
        }
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
        /// Between a screen's regions — ma: the pause that groups things
        /// without a line.
        static let section: CGFloat = 40
        static let xxxl: CGFloat = 56
    }

    enum Radius {
        static let tail: CGFloat = 6
        static let chip: CGFloat = 10
        static let control: CGFloat = 14
        static let bubble: CGFloat = 19
        /// Thread cards and content cards.
        static let card: CGFloat = 20
        /// Large hero cards (day header, body hero).
        static let cardLarge: CGFloat = 24
        static let sheet: CGFloat = 30

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

    enum Layout {
        /// Every card in the coach thread (meals, workouts, check-ins and
        /// Shudo's rich cards) shares one width so the column reads clean.
        static let threadCardWidth: CGFloat = 300
    }

    /// Weighted springs with no bounce: things glide and settle once, like a
    /// shoji door sliding home. Gate everything through `gated` (or the
    /// `.calm` transitions) so Reduce Motion gets fades only.
    enum Motion {
        /// Small state changes: toggles, chips, selection, press feedback.
        static let snap = Animation.spring(response: 0.32, dampingFraction: 0.9)
        /// Default layout motion — a panel or region moving to its new place.
        static let settle = Animation.spring(response: 0.55, dampingFraction: 0.92)
        /// New things entering (a message, a card, a sheet's content).
        static let arrive = Animation.spring(response: 0.62, dampingFraction: 0.88)
        /// Slower slides between whole states (day switching, mode changes).
        static let shoji = Animation.spring(response: 0.72, dampingFraction: 0.94)
        /// Fades: ink appearing on paper.
        static let breath = Animation.easeInOut(duration: 0.45)
        /// Rings and meters filling.
        static let ring = Animation.spring(response: 1.0, dampingFraction: 0.9)
        static func gated(_ animation: Animation, reduceMotion: Bool) -> Animation? {
            reduceMotion ? nil : animation
        }
        /// Like `gated`, but keeps a plain fade under Reduce Motion — for state
        /// changes that would otherwise pop.
        static func calm(_ animation: Animation, reduceMotion: Bool) -> Animation {
            reduceMotion ? .easeInOut(duration: 0.2) : animation
        }
    }
}

// MARK: - Transitions

/// Ink settling on paper: a soft blur clearing, a small rise, a fade.
private struct InkSettle: ViewModifier {
    let progress: Double

    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .blur(radius: (1 - progress) * 6)
            .offset(y: (1 - progress) * 10)
    }
}

extension AnyTransition {
    /// New content arriving (messages, cards, results). Fade only under Reduce Motion.
    static func ink(reduceMotion: Bool) -> AnyTransition {
        reduceMotion
            ? .opacity
            : .modifier(active: InkSettle(progress: 0), identity: InkSettle(progress: 1))
    }

    /// A panel sliding in from an edge, shoji-style, a short distance.
    static func shoji(_ edge: Edge, reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        let distance: CGFloat = 24
        let offset: CGSize = switch edge {
        case .top: CGSize(width: 0, height: -distance)
        case .bottom: CGSize(width: 0, height: distance)
        case .leading: CGSize(width: -distance, height: 0)
        case .trailing: CGSize(width: distance, height: 0)
        }
        return .offset(offset).combined(with: .opacity)
    }
}

// MARK: - Materials

extension View {
    /// Liquid Glass for floating chrome only (headers, capture bar, pills).
    /// Content cards stay opaque (`cardSurface`).
    func chromeGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
    }

    /// An opaque walnut panel. No border — just a faint top-lit edge, the way
    /// lamplight catches the lip of a lacquer tray.
    func cardSurface(radius: CGFloat = Design.Radius.card) -> some View {
        background(
            Design.Color.surface1,
            in: RoundedRectangle(cornerRadius: radius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Design.Color.hinoki.opacity(0.10), Design.Color.hinoki.opacity(0.015)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: Design.Stroke.hairline
                )
                .allowsHitTesting(false)
        )
    }

    /// A quiet sentence-case label. Luke wants no uppercase anywhere.
    func eyebrowStyle(_ color: Color = Design.Color.textTertiary) -> some View {
        font(Design.Typeface.eyebrow)
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
                            colors: [.clear, Design.Color.hinoki.opacity(0.22), .clear],
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
                    withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: false)) {
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

/// The one primary action on a screen: a hinoki-cream slab with sumi ink.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Design.Typeface.text(.subheadline, weight: .semibold))
            .foregroundStyle(Design.Color.onCream)
            .padding(.horizontal, 20)
            .padding(.vertical, 13)
            .background(
                Design.Color.hinoki.opacity(isEnabled ? 1 : 0.35),
                in: RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(Design.Motion.snap, value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Design.Typeface.text(.subheadline, weight: .semibold))
            .foregroundStyle(Design.Color.textPrimary)
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            .background(
                Design.Color.surface2,
                in: RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(Design.Motion.snap, value: configuration.isPressed)
    }
}
