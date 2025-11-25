import SwiftUI

struct AppBackground: View {
    var body: some View {
        ZStack {
            // Base - deep dark
            Design.Color.paper
                .ignoresSafeArea()

            // Subtle gradient overlay for depth
            LinearGradient(
                colors: [
                    Design.Color.accentPrimary.opacity(0.03),
                    .clear,
                    Design.Color.success.opacity(0.02)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            // Vignette effect
            RadialGradient(
                colors: [
                    .clear,
                    Design.Color.paper.opacity(0.5)
                ],
                center: .center,
                startRadius: 200,
                endRadius: 600
            )
            .ignoresSafeArea()
        }
    }
}
