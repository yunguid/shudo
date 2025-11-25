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
        static let glassElev = SwiftUI.Color(red: 0.118, green: 0.133, blue: 0.180).opacity(0.8) // Elevated elements
        static let fill = glassFill

        // Primary accent - Electric Blue
        static let accentPrimary   = SwiftUI.Color(red: 0.263, green: 0.522, blue: 0.957)  // #4385F4 - vibrant blue
        static let accentSecondary = SwiftUI.Color(red: 0.392, green: 0.616, blue: 0.965)  // #649DF6 - lighter blue
        
        // Success / Positive - Fresh Green
        static let success = SwiftUI.Color(red: 0.275, green: 0.824, blue: 0.475)          // #46D279 - fresh green
        static let ok = success

        // Macro rings - refined palette
        static let ringProtein = SwiftUI.Color(red: 0.545, green: 0.710, blue: 0.996)      // #8BB5FE - soft blue
        static let ringCarb    = SwiftUI.Color(red: 0.275, green: 0.824, blue: 0.475)      // #46D279 - green
        static let ringFat     = SwiftUI.Color(red: 0.957, green: 0.757, blue: 0.263)      // #F4C143 - warm amber

        static func ring(_ c: SwiftUI.Color) -> SwiftUI.Color { c.opacity(0.96) }

        // Warning / Danger
        static let danger = SwiftUI.Color(red: 0.976, green: 0.318, blue: 0.380)           // #F95161 - soft red
        static let warning = SwiftUI.Color(red: 0.957, green: 0.757, blue: 0.263)          // #F4C143 - amber

        // Back-compat
        static let inkLegacy = ink
        static let accent = accentPrimary
    }

    enum Spacing {
        static let xs: CGFloat = 6
        static let s:  CGFloat = 10
        static let m:  CGFloat = 14
        static let l:  CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
    }

    enum Radius {
        static let s:  CGFloat = 8
        static let m:  CGFloat = 12
        static let l:  CGFloat = 16
        static let xl: CGFloat = 24
        static let pill: CGFloat = 999
    }

    enum Stroke {
        static let hairline: CGFloat = 0.5
        static let thin: CGFloat = 1
    }
}

// MARK: - Common Surfaces

private struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: Design.Radius.l, style: .continuous)
                    .fill(Design.Color.glassFill)
                    .background(
                        RoundedRectangle(cornerRadius: Design.Radius.l, style: .continuous)
                            .fill(.ultraThinMaterial.opacity(0.3))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: Design.Radius.l, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.10), Color.white.opacity(0.03)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        lineWidth: Design.Stroke.hairline
                    )
            )
    }
}

extension View {
    func cardStyle() -> some View { modifier(CardBackground()) }
    func hairlineDivider() -> some View {
        Rectangle()
            .fill(Design.Color.rule)
            .frame(height: Design.Stroke.hairline)
    }
}

// MARK: - Fields

struct FieldBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: Design.Radius.m, style: .continuous)
                    .fill(Design.Color.elevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Design.Radius.m, style: .continuous)
                    .stroke(Design.Color.rule, lineWidth: Design.Stroke.hairline)
            )
    }
}
extension View {
    func fieldStyle() -> some View { modifier(FieldBackground()) }
}

// MARK: - Section UX

struct SectionHeader: View {
    let title: String
    let subtitle: String?

    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Design.Color.ink)
                .textCase(.uppercase)
                .tracking(0.5)
            if let s = subtitle {
                Text(s).font(.footnote).foregroundStyle(Design.Color.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SectionCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .padding(16)
            .cardStyle()
    }
}

// MARK: - Linear Gauge

struct GaugeCapsule: View {
    let progress: Double     // 0...1
    let height: CGFloat
    let gradient: LinearGradient

    init(progress: Double, height: CGFloat = 10, gradient: LinearGradient = LinearGradient(colors: [Design.Color.accentSecondary, Design.Color.accentPrimary], startPoint: .leading, endPoint: .trailing)) {
        self.progress = progress
        self.height = height
        self.gradient = gradient
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Design.Color.elevated)
                Capsule()
                    .fill(gradient)
                    .frame(width: max(0, min(width * max(0, min(progress, 1)), width)))
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int(progress * 100)) percent")
    }
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

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Design.Color.accentPrimary)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Design.Color.elevated, in: RoundedRectangle(cornerRadius: Design.Radius.m, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Design.Radius.m, style: .continuous)
                    .stroke(Design.Color.accentPrimary.opacity(0.3), lineWidth: Design.Stroke.thin)
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}
