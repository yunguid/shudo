import SwiftUI

// Minimal design system to unify spacing, corners, and common components
enum Design {
    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Radius {
        static let s: CGFloat = 10
        static let m: CGFloat = 12
        static let l: CGFloat = 14
        static let xl: CGFloat = 20
    }
}

// Consistent card surface used across the app
private struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: Design.Radius.l, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Design.Radius.l, style: .continuous)
                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
            )
    }
}

extension View {
    func cardStyle() -> some View { modifier(CardBackground()) }
}

// Standard section header used in lists/sections
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
                Text(s).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// A simple container to apply padding and card styling to sections
struct SectionCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View { content.padding(12).cardStyle() }
}

// Reusable linear gauge with elegant capsule look
struct GaugeCapsule: View {
    let progress: Double
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
                Capsule().fill(Color.gray.opacity(0.15))
                Capsule()
                    .fill(gradient)
                    .frame(width: max(0, min(width * progress, width)))
            }
        }
        .frame(height: height)
    }
}


