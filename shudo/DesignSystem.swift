import SwiftUI

// MARK: - Design System
// Monochrome-first palette + rational spacing and radii.
enum Design {
    enum Color {
        static let ink = SwiftUI.Color(.label)               // dynamic primary
        static let paper = SwiftUI.Color(.systemBackground)  // dynamic surface
        static let muted = SwiftUI.Color(.secondaryLabel)
        static let rule = SwiftUI.Color.black.opacity(0.08)
        static let fill = SwiftUI.Color(.secondarySystemBackground)
        static let accent = SwiftUI.Color.accentColor
        static func ring(_ base: SwiftUI.Color) -> SwiftUI.Color { base.opacity(0.92) }
        static let danger = SwiftUI.Color.red
        static let ok = SwiftUI.Color.green
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let s:  CGFloat = 8
        static let m:  CGFloat = 12
        static let l:  CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl:CGFloat = 32
    }

    enum Radius {
        static let s:  CGFloat = 10
        static let m:  CGFloat = 12
        static let l:  CGFloat = 14
        static let xl: CGFloat = 20
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
                    .fill(Design.Color.fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Design.Radius.l, style: .continuous)
                    .stroke(Design.Color.rule, lineWidth: Design.Stroke.hairline)
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
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
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
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
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
            .padding(12)
            .cardStyle()
    }
}

// MARK: - Linear Gauge

struct GaugeCapsule: View {
    let progress: Double     // 0...1
    let height: CGFloat
    let gradient: LinearGradient

    init(progress: Double, height: CGFloat = 10, gradient: LinearGradient = LinearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing)) {
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
