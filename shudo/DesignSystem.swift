import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case groovebox
    case moss
    case dusk

    static let storageKey = "shudo.appearance.theme"
    static let defaultTheme: AppTheme = .groovebox

    var id: String { rawValue }

    var title: String {
        switch self {
        case .groovebox: "Studio"
        case .moss: "Carbon"
        case .dusk: "Oxide"
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .groovebox: "Warm neutral on charcoal"
        case .moss: "Cool silver on near black"
        case .dusk: "Muted copper on warm black"
        }
    }

    var palette: Design.Palette {
        switch self {
        case .groovebox:
            Design.Palette(
                paper: Color(red: 0.035, green: 0.037, blue: 0.040),
                elevated: Color(red: 0.082, green: 0.084, blue: 0.089),
                ink: Color(red: 0.935, green: 0.925, blue: 0.895),
                muted: Color(red: 0.610, green: 0.600, blue: 0.570),
                subtle: Color(red: 0.340, green: 0.340, blue: 0.330),
                accentPrimary: Color(red: 0.790, green: 0.735, blue: 0.610),
                accentSecondary: Color(red: 0.670, green: 0.625, blue: 0.535),
                ctaPrimary: Color(red: 0.315, green: 0.295, blue: 0.250),
                ctaSecondary: Color(red: 0.225, green: 0.215, blue: 0.190),
                success: Color(red: 0.380, green: 0.690, blue: 0.505),
                ringProtein: Color(red: 0.515, green: 0.650, blue: 0.705),
                ringCarb: Color(red: 0.500, green: 0.665, blue: 0.555),
                ringFat: Color(red: 0.735, green: 0.625, blue: 0.445)
            )
        case .moss:
            Design.Palette(
                paper: Color(red: 0.025, green: 0.027, blue: 0.030),
                elevated: Color(red: 0.072, green: 0.077, blue: 0.081),
                ink: Color(red: 0.915, green: 0.925, blue: 0.920),
                muted: Color(red: 0.565, green: 0.590, blue: 0.585),
                subtle: Color(red: 0.315, green: 0.335, blue: 0.335),
                accentPrimary: Color(red: 0.735, green: 0.765, blue: 0.760),
                accentSecondary: Color(red: 0.555, green: 0.605, blue: 0.610),
                ctaPrimary: Color(red: 0.235, green: 0.265, blue: 0.270),
                ctaSecondary: Color(red: 0.175, green: 0.195, blue: 0.200),
                success: Color(red: 0.385, green: 0.680, blue: 0.535),
                ringProtein: Color(red: 0.500, green: 0.625, blue: 0.690),
                ringCarb: Color(red: 0.475, green: 0.650, blue: 0.555),
                ringFat: Color(red: 0.710, green: 0.620, blue: 0.465)
            )
        case .dusk:
            Design.Palette(
                paper: Color(red: 0.045, green: 0.037, blue: 0.033),
                elevated: Color(red: 0.100, green: 0.082, blue: 0.073),
                ink: Color(red: 0.930, green: 0.900, blue: 0.855),
                muted: Color(red: 0.625, green: 0.575, blue: 0.535),
                subtle: Color(red: 0.355, green: 0.305, blue: 0.280),
                accentPrimary: Color(red: 0.710, green: 0.500, blue: 0.360),
                accentSecondary: Color(red: 0.635, green: 0.545, blue: 0.455),
                ctaPrimary: Color(red: 0.335, green: 0.220, blue: 0.160),
                ctaSecondary: Color(red: 0.245, green: 0.165, blue: 0.125),
                success: Color(red: 0.415, green: 0.675, blue: 0.500),
                ringProtein: Color(red: 0.505, green: 0.625, blue: 0.670),
                ringCarb: Color(red: 0.505, green: 0.650, blue: 0.535),
                ringFat: Color(red: 0.735, green: 0.565, blue: 0.390)
            )
        }
    }

    static var selected: AppTheme {
        guard let stored = UserDefaults.standard.string(forKey: storageKey),
              let theme = AppTheme(rawValue: stored) else { return defaultTheme }
        return theme
    }
}

// MARK: - Design System

enum Design {
    struct Palette {
        let paper: SwiftUI.Color
        let elevated: SwiftUI.Color
        let ink: SwiftUI.Color
        let muted: SwiftUI.Color
        let subtle: SwiftUI.Color
        let accentPrimary: SwiftUI.Color
        let accentSecondary: SwiftUI.Color
        let ctaPrimary: SwiftUI.Color
        let ctaSecondary: SwiftUI.Color
        let success: SwiftUI.Color
        let ringProtein: SwiftUI.Color
        let ringCarb: SwiftUI.Color
        let ringFat: SwiftUI.Color
    }

    enum Color {
        private static var palette: Palette { AppTheme.selected.palette }

        static var paper: SwiftUI.Color { palette.paper }
        static var elevated: SwiftUI.Color { palette.elevated }
        static var ink: SwiftUI.Color { palette.ink }
        static var muted: SwiftUI.Color { palette.muted }
        static var subtle: SwiftUI.Color { palette.subtle }
        static var rule: SwiftUI.Color { palette.ink.opacity(0.14) }
        static var glassFill: SwiftUI.Color { palette.elevated.opacity(0.94) }
        static var heatmapEmpty: SwiftUI.Color { palette.ink.opacity(0.105) }
        static var heatmapBorder: SwiftUI.Color { palette.ink.opacity(0.20) }
        static var accentPrimary: SwiftUI.Color { palette.accentPrimary }
        static var accentSecondary: SwiftUI.Color { palette.accentSecondary }
        static var ctaPrimary: SwiftUI.Color { palette.ctaPrimary }
        static var ctaSecondary: SwiftUI.Color { palette.ctaSecondary }
        static var success: SwiftUI.Color { palette.success }
        static var ringProtein: SwiftUI.Color { palette.ringProtein }
        static var ringCarb: SwiftUI.Color { palette.ringCarb }
        static var ringFat: SwiftUI.Color { palette.ringFat }
        static let danger = SwiftUI.Color(red: 0.976, green: 0.318, blue: 0.380)
        static let warning = SwiftUI.Color(red: 0.957, green: 0.757, blue: 0.263)
    }

    enum Radius {
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let panel: CGFloat = 18
        static let xl: CGFloat = 20
        static let card: CGFloat = 22
        static let hero: CGFloat = 24
        static let sheet: CGFloat = 28
    }

    enum Stroke {
        static let hairline: CGFloat = 0.5
    }
}

/// One consistent hairline rule; Divider ignores tint and renders the system
/// separator color, so lists use this instead.
struct HairlineRule: View {
    var body: some View {
        Rectangle()
            .fill(Design.Color.rule)
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
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(
                LinearGradient(
                    colors: [Design.Color.ctaPrimary, Design.Color.ctaSecondary],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                in: RoundedRectangle(cornerRadius: Design.Radius.m, style: .continuous)
            )
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
    }
}
