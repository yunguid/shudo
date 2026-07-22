import SwiftUI

struct AppBackground: View {
    var body: some View {
        ZStack {
            Design.Color.paper
                .ignoresSafeArea()

            LinearGradient(
                colors: [
                    Design.Color.accentPrimary.opacity(0.045),
                    .clear,
                    Design.Color.accentSecondary.opacity(0.025)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Canvas { context, size in
                for y in stride(from: 12.0, through: size.height, by: 18.0) {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(path, with: .color(Design.Color.ink.opacity(0.018)), lineWidth: 0.5)
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            RadialGradient(
                colors: [
                    .clear,
                    Design.Color.paper.opacity(0.58)
                ],
                center: .center,
                startRadius: 200,
                endRadius: 600
            )
            .ignoresSafeArea()
        }
        .drawingGroup(opaque: true)
    }
}
