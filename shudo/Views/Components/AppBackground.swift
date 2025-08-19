import SwiftUI

struct AppBackground: View {
    var body: some View {
        ZStack {
            RadialGradient(
                colors: [
                    Design.Color.paper,
                    Design.Color.paper.opacity(0.96)
                ],
                center: .topLeading, startRadius: 80, endRadius: 900
            )
            .ignoresSafeArea()

            // faint aurora wash for depth
            LinearGradient(
                colors: [
                    Design.Color.accentPrimary.opacity(0.06),
                    .clear,
                    Design.Color.accentSecondary.opacity(0.05)
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .blendMode(.plusLighter)
            .ignoresSafeArea()
        }
    }
}


