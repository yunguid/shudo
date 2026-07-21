import SwiftUI

// MARK: - Design System
// Dark-first palette: deep blacks, electric blue, crisp white, accent green
enum Design {
    enum Color {
        // Core backgrounds (true dark)
        static let paper = SwiftUI.Color(red: 0.035, green: 0.039, blue: 0.055)            // #090A0E - near black
        static let elevated = SwiftUI.Color(red: 0.055, green: 0.063, blue: 0.090)         // #0E1017 - slightly lifted
        
        // Text
        static let ink   = SwiftUI.Color.white                                             // Primary text
        static let muted = SwiftUI.Color(red: 0.478, green: 0.502, blue: 0.565)            // #7A80A0 - muted blue-gray
        static let subtle = SwiftUI.Color(red: 0.318, green: 0.345, blue: 0.408)           // #515868

        // Surface / Fills
        static let rule      = SwiftUI.Color.white.opacity(0.08)                           // Hairlines
        static let glassFill = SwiftUI.Color(red: 0.098, green: 0.110, blue: 0.149).opacity(0.7) // Card fill

        // Primary accent - Electric Blue
        static let accentPrimary   = SwiftUI.Color(red: 0.263, green: 0.522, blue: 0.957)  // #4385F4 - vibrant blue
        static let accentSecondary = SwiftUI.Color(red: 0.392, green: 0.616, blue: 0.965)  // #649DF6 - lighter blue
        
        // Success / Positive - Fresh Green
        static let success = SwiftUI.Color(red: 0.275, green: 0.824, blue: 0.475)          // #46D279 - fresh green

        // Macro rings - refined palette
        static let ringProtein = SwiftUI.Color(red: 0.545, green: 0.710, blue: 0.996)      // #8BB5FE - soft blue
        static let ringCarb    = SwiftUI.Color(red: 0.275, green: 0.824, blue: 0.475)      // #46D279 - green
        static let ringFat     = SwiftUI.Color(red: 0.957, green: 0.757, blue: 0.263)      // #F4C143 - warm amber

        // Warning / Danger
        static let danger = SwiftUI.Color(red: 0.976, green: 0.318, blue: 0.380)           // #F95161 - soft red
        static let warning = SwiftUI.Color(red: 0.957, green: 0.757, blue: 0.263)          // #F4C143 - amber
    }

    enum Radius {
        static let s:  CGFloat = 8
        static let m:  CGFloat = 12
        static let l:  CGFloat = 16
    }

    enum Stroke {
        static let hairline: CGFloat = 0.5
    }
}

private struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { geometry in
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.48), .clear],
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

extension View {
    func shimmering() -> some View { modifier(ShimmerModifier()) }
}

// MARK: - Button Styles

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Design.Color.accentPrimary, in: RoundedRectangle(cornerRadius: Design.Radius.m, style: .continuous))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}
