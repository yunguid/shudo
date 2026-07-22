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
        case .groovebox: "Groove"
        case .moss: "Moss"
        case .dusk: "Dusk"
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .groovebox: "Warm orange on charcoal"
        case .moss: "Soft green on deep forest"
        case .dusk: "Muted violet on aubergine"
        }
    }

    var palette: Design.Palette {
        switch self {
        case .groovebox:
            Design.Palette(
                paper: Color(red: 0.035, green: 0.033, blue: 0.030),
                elevated: Color(red: 0.078, green: 0.070, blue: 0.061),
                ink: Color(red: 0.965, green: 0.945, blue: 0.910),
                muted: Color(red: 0.690, green: 0.661, blue: 0.615),
                subtle: Color(red: 0.375, green: 0.345, blue: 0.305),
                accentPrimary: Color(red: 0.996, green: 0.565, blue: 0.302),
                accentSecondary: Color(red: 0.925, green: 0.695, blue: 0.420),
                ctaPrimary: Color(red: 0.545, green: 0.235, blue: 0.075),
                ctaSecondary: Color(red: 0.430, green: 0.170, blue: 0.060),
                success: Color(red: 0.510, green: 0.765, blue: 0.475),
                ringProtein: Color(red: 0.475, green: 0.735, blue: 0.790),
                ringCarb: Color(red: 0.510, green: 0.765, blue: 0.475),
                ringFat: Color(red: 0.925, green: 0.695, blue: 0.420)
            )
        case .moss:
            Design.Palette(
                paper: Color(red: 0.025, green: 0.045, blue: 0.038),
                elevated: Color(red: 0.055, green: 0.090, blue: 0.075),
                ink: Color(red: 0.925, green: 0.955, blue: 0.920),
                muted: Color(red: 0.625, green: 0.700, blue: 0.645),
                subtle: Color(red: 0.285, green: 0.390, blue: 0.330),
                accentPrimary: Color(red: 0.510, green: 0.820, blue: 0.610),
                accentSecondary: Color(red: 0.690, green: 0.835, blue: 0.590),
                ctaPrimary: Color(red: 0.115, green: 0.405, blue: 0.260),
                ctaSecondary: Color(red: 0.090, green: 0.320, blue: 0.220),
                success: Color(red: 0.510, green: 0.820, blue: 0.610),
                ringProtein: Color(red: 0.510, green: 0.735, blue: 0.790),
                ringCarb: Color(red: 0.510, green: 0.820, blue: 0.610),
                ringFat: Color(red: 0.880, green: 0.730, blue: 0.390)
            )
        case .dusk:
            Design.Palette(
                paper: Color(red: 0.050, green: 0.035, blue: 0.065),
                elevated: Color(red: 0.095, green: 0.065, blue: 0.115),
                ink: Color(red: 0.955, green: 0.930, blue: 0.965),
                muted: Color(red: 0.700, green: 0.635, blue: 0.720),
                subtle: Color(red: 0.400, green: 0.325, blue: 0.430),
                accentPrimary: Color(red: 0.835, green: 0.570, blue: 0.920),
                accentSecondary: Color(red: 0.955, green: 0.600, blue: 0.690),
                ctaPrimary: Color(red: 0.410, green: 0.205, blue: 0.515),
                ctaSecondary: Color(red: 0.350, green: 0.155, blue: 0.440),
                success: Color(red: 0.500, green: 0.790, blue: 0.650),
                ringProtein: Color(red: 0.530, green: 0.700, blue: 0.930),
                ringCarb: Color(red: 0.500, green: 0.790, blue: 0.650),
                ringFat: Color(red: 0.940, green: 0.690, blue: 0.440)
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
        static var rule: SwiftUI.Color { palette.ink.opacity(0.10) }
        static var glassFill: SwiftUI.Color { palette.elevated.opacity(0.82) }
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
    }

    enum Stroke {
        static let hairline: CGFloat = 0.5
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
