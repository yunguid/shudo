import SwiftUI

/// The room every screen sits in: sumi-walnut, with lamplight from above —
/// a faint warm wash at the top that fades out well before the content.
struct AppBackground: View {
    var body: some View {
        Design.Color.canvas
            .overlay(alignment: .top) {
                RadialGradient(
                    colors: [Design.Color.pernambuco.opacity(0.07), .clear],
                    center: UnitPoint(x: 0.3, y: 0),
                    startRadius: 0,
                    endRadius: 460
                )
                .frame(height: 520)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}
