import SwiftUI

// MARK: - Design System
// Brand-led palette and rational spacing/radii. Tuned for legibility.
enum Design {
    enum Color {
        // Neutrals (dark-first)
        static let paper = SwiftUI.Color(red: 0.059, green: 0.075, blue: 0.067)            // #0F1311
        static let ink   = SwiftUI.Color.white                                             // #FFFFFF for maximum legibility
        static let muted = SwiftUI.Color(red: 0.607, green: 0.639, blue: 0.620)            // #9BA39E

        // Hairlines / fills (glassy)
        static let rule      = SwiftUI.Color.white.opacity(0.10) // slightly stronger hairline for clarity
        static let glassFill = SwiftUI.Color.white.opacity(0.06) // card fill on dark
        static let glassElev = SwiftUI.Color.white.opacity(0.08) // slight bump for elevated pills/chips

        // Accents
        static let accentPrimary   = SwiftUI.Color(red: 0.169, green: 0.541, blue: 0.431)  // #2B8A6E
        static let accentSecondary = SwiftUI.Color(red: 0.514, green: 0.647, blue: 0.596)  // #83A598

        // Macros
        static let ringProtein = SwiftUI.Color(red: 0.827, green: 0.525, blue: 0.608)      // #D3869B (floral pink)
        static let ringCarb    = SwiftUI.Color(red: 0.557, green: 0.753, blue: 0.486)      // #8EC07C
        static let ringFat     = SwiftUI.Color(red: 0.847, green: 0.600, blue: 0.129)      // #D79921

        static func ring(_ c: SwiftUI.Color) -> SwiftUI.Color { c.opacity(0.96) }

        static let danger = SwiftUI.Color(red: 0.918, green: 0.329, blue: 0.333)           // #EA5455

        // Back-compat aliases (minimize churn)
        static let inkLegacy = ink
        static let fill = glassFill
        static let accent = accentPrimary
        static let ok = SwiftUI.Color(red: 0.28, green: 0.80, blue: 0.48)
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
        static let s:  CGFloat = 10
        static let m:  CGFloat = 12
        static let l:  CGFloat = 14
        static let xl: CGFloat = 22
        static let pill: CGFloat = 999
    }

    enum Stroke {
        static let hairline: CGFloat = 1
    }
}

// MARK: - Common Surfaces

private struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: Design.Radius.l, style: .continuous)
                    .fill(.ultraThinMaterial) // glass
                    .background(Design.Color.glassFill) // subtle tint for dark
                    .clipShape(RoundedRectangle(cornerRadius: Design.Radius.l, style: .continuous))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Design.Radius.l, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.14), Color.white.opacity(0.06)],
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
                    .fill(Design.Color.fill)
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
            Text(title).font(.headline.weight(.semibold)).foregroundStyle(Design.Color.ink)
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

    init(progress: Double, height: CGFloat = 12, gradient: LinearGradient = LinearGradient(colors: [Design.Color.accentSecondary, Design.Color.accentPrimary], startPoint: .leading, endPoint: .trailing)) {
        self.progress = progress
        self.height = height
        self.gradient = gradient
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Design.Color.rule.opacity(0.6))
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
