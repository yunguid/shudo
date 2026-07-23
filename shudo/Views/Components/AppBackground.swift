import SwiftUI

struct AppBackground: View {
    var body: some View {
        ZStack {
            Design.Color.paper
                .ignoresSafeArea()

            LinearGradient(
                colors: [
                    Design.Color.ink.opacity(0.018),
                    .clear,
                    Design.Color.accentPrimary.opacity(0.018)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            RadialGradient(
                colors: [
                    .clear,
                    Design.Color.paper.opacity(0.32)
                ],
                center: .center,
                startRadius: 200,
                endRadius: 600
            )
            .ignoresSafeArea()
        }
    }
}
