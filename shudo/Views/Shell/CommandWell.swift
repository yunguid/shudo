import SwiftUI
import UIKit

// MARK: - The command band
//
// The bottom of the app is one reserved band: on the left, a well carved out
// of the screen's bottom-left corner holding Shudo's key (tap to talk, hold
// for the dial); on the right, the tab bar. The band is opaque and the shell
// pads every tab's safe area by its height (`shellBandInset`), so nothing —
// text, icons, cards, the thread's last message — ever tangles with the well.

/// Geometry of the command band, derived from the device's display corner so
/// the well's outer corner is the screen's own corner and the key sits
/// concentric with it.
struct CommandBandMetrics: Equatable {
    /// The Shudo key's diameter.
    static let keyDiameter: CGFloat = 56
    /// The small, even margin between the key and the well's rim.
    static let rimGap: CGFloat = 5
    /// The tab bar's (and the recording strip's) height.
    static let barHeight: CGFloat = 54
    /// Well → tab bar.
    static let barGap: CGFloat = 10
    static let trailingMargin: CGFloat = 16
    /// Breathing room between the content above and the well's lip; content
    /// scrolling down into it dissolves before it reaches the lip.
    static let topGap: CGFloat = 16
    /// The tab bar's and recording strip's glass: warmed toward walnut so it
    /// sits on the band like lacquer, not grey plastic.
    static let barTint = Color(hex: 0x3A2A21).opacity(0.45)
    /// The fillet where the well's lip meets the left screen edge.
    static let filletRadius: CGFloat = 12

    /// Screen display corner radius (0 on square-cornered screens).
    let displayCornerRadius: CGFloat
    /// The window's bottom safe-area inset (home indicator).
    let bottomSafeArea: CGFloat

    var keyRadius: CGFloat { Self.keyDiameter / 2 }

    /// Distance of the key's center from the left and bottom screen edges:
    /// close enough to the corner to feel tucked in, never closer to the
    /// rounded display corner than the rim gap.
    var keyCenterInset: CGFloat {
        let r = displayCornerRadius
        let concentric = r - (r - keyRadius - Self.rimGap) / 2.squareRoot()
        return max(keyRadius + 12, concentric)
    }

    /// The well is square: from the corner out past the key by the rim gap.
    var wellSide: CGFloat { keyCenterInset + keyRadius + Self.rimGap }
    /// Concentric with the key.
    var wellCornerRadius: CGFloat { keyRadius + Self.rimGap }

    /// How much of the band sits above the home-indicator safe area — the
    /// bottom safe-area padding every tab gets.
    var safeAreaInset: CGFloat { max(0, wellSide - bottomSafeArea) + Self.topGap }

    /// Total band height measured from the screen's bottom edge.
    var bandHeight: CGFloat { wellSide + Self.topGap }

    static let fallback = CommandBandMetrics(displayCornerRadius: 55, bottomSafeArea: 34)
}

enum DisplayCorner {
    /// The physical display's corner radius, so the well follows the glass.
    /// UIKit keeps it private; read it defensively and fall back to the
    /// Face ID iPhone family's typical radius.
    @MainActor
    static var radius: CGFloat {
        let screen = (UIApplication.shared.connectedScenes.first { $0 is UIWindowScene } as? UIWindowScene)?.screen
        let key = ["_display", "Corner", "Radius"].joined()
        if let screen, screen.responds(to: NSSelectorFromString(key)),
           let value = screen.value(forKey: key) as? CGFloat, value > 0 {
            return value
        }
        return 55
    }
}

extension EnvironmentValues {
    /// The command band's height above the home-indicator safe area. The
    /// shell already pads every tab's safe area by this; a screen only needs
    /// it to place something that ignores the safe area.
    @Entry var shellBandInset: CGFloat = 0
    /// Pushed screens that bring their own bottom bar (the meal page's fix
    /// bar) call this with `true` on appear and `false` on disappear so the
    /// band steps aside.
    @Entry var setShellBandSuppressed: (Bool) -> Void = { _ in }
}

/// Gives the hosting tab controller the band's height as extra bottom safe
/// area, so every tab — through its navigation stacks and pushed pages —
/// lays out above the band. (SwiftUI's own safe-area modifiers don't cross
/// into the tabs' UIKit-backed navigation stacks.)
struct TabSafeAreaInset: UIViewControllerRepresentable {
    var bottom: CGFloat

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.bottom = bottom
        controller.apply()
    }

    final class Controller: UIViewController {
        var bottom: CGFloat = 0

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            apply()
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            apply()
        }

        func apply() {
            var candidate = parent
            while let current = candidate, !(current is UITabBarController) {
                candidate = current.parent
            }
            guard let tabs = candidate as? UITabBarController,
                  tabs.additionalSafeAreaInsets.bottom != bottom else { return }
            tabs.additionalSafeAreaInsets.bottom = bottom
        }
    }
}

// MARK: - Well

/// The well's outline: the screen's bottom-left corner, carved out to a
/// square with a rounded inner corner; the lip flows into the left screen
/// edge through a small fillet, the wall runs straight into the bottom. `rect` is the full screen.
struct CommandWellShape: Shape {
    var side: CGFloat
    var cornerRadius: CGFloat
    var fillet: CGFloat = CommandBandMetrics.filletRadius

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let top = rect.maxY - side
        let right = rect.minX + side
        // Up the left screen edge past the fillet, then into the lip.
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: top - fillet))
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: top),
            tangent2End: CGPoint(x: rect.minX + fillet, y: top),
            radius: fillet
        )
        path.addLine(to: CGPoint(x: right - cornerRadius, y: top))
        path.addArc(
            tangent1End: CGPoint(x: right, y: top),
            tangent2End: CGPoint(x: right, y: top + cornerRadius),
            radius: cornerRadius
        )
        path.addLine(to: CGPoint(x: right, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Just the visible rim of the well (lip, inner corner, wall), open at the
/// screen edges, for the machined edge stroke.
struct CommandWellRim: Shape {
    var side: CGFloat
    var cornerRadius: CGFloat
    var fillet: CGFloat = CommandBandMetrics.filletRadius

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let top = rect.maxY - side
        let right = rect.minX + side
        path.move(to: CGPoint(x: rect.minX, y: top - fillet))
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: top),
            tangent2End: CGPoint(x: rect.minX + fillet, y: top),
            radius: fillet
        )
        path.addLine(to: CGPoint(x: right - cornerRadius, y: top))
        path.addArc(
            tangent1End: CGPoint(x: right, y: top),
            tangent2End: CGPoint(x: right, y: top + cornerRadius),
            radius: cornerRadius
        )
        path.addLine(to: CGPoint(x: right, y: rect.maxY))
        return path
    }
}

/// The carved corner itself: a recess a shade deeper than the canvas, shaded
/// under its lip, edged with a fine warm-titanium rim that catches the
/// lamplight at the lip and falls off down the wall. Drawn full-screen; the
/// display's own rounded corner finishes the outer edge.
struct CommandWell: View {
    let metrics: CommandBandMetrics

    private static let recessTop = Color(hex: 0x070504)
    private static let recessBottom = Color(hex: 0x0B0907)
    /// Warm titanium: hinoki with the colour drawn out of it.
    private static let metal = Color(hex: 0xE6DCCD)

    var body: some View {
        let shape = CommandWellShape(side: metrics.wellSide, cornerRadius: metrics.wellCornerRadius)
        let rim = CommandWellRim(side: metrics.wellSide, cornerRadius: metrics.wellCornerRadius)
        GeometryReader { proxy in
            let size = proxy.size
            let top = (size.height - metrics.wellSide) / max(size.height, 1)
            ZStack {
                shape.fill(
                    LinearGradient(
                        colors: [Self.recessTop, Self.recessBottom],
                        startPoint: UnitPoint(x: 0.5, y: top),
                        endPoint: .bottom
                    )
                )
                // Shadow cast by the lip into the recess.
                shape.fill(
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0.55), location: 0),
                            .init(color: .black.opacity(0), location: 1),
                        ],
                        startPoint: UnitPoint(x: 0.5, y: top),
                        endPoint: UnitPoint(x: 0.5, y: top + 18 / max(size.height, 1))
                    )
                )
                // The inner wall: a dark line just inside the rim.
                rim.offset(x: -0.75, y: 0.75)
                    .stroke(Color.black.opacity(0.7), lineWidth: 1.5)
                // The machined lip: bright where the light catches the
                // corner, falling off along the lip and down the wall.
                rim.stroke(
                    LinearGradient(
                        stops: [
                            .init(color: Self.metal.opacity(0.12), location: 0),
                            .init(color: Self.metal.opacity(0.34), location: 0.36),
                            .init(color: Self.metal.opacity(0.62), location: 0.5),
                            .init(color: Self.metal.opacity(0.28), location: 0.68),
                            .init(color: Self.metal.opacity(0.05), location: 1),
                        ],
                        startPoint: UnitPoint(x: 0, y: top),
                        endPoint: UnitPoint(
                            x: metrics.wellSide / max(size.width, 1),
                            y: 1
                        )
                    ),
                    lineWidth: 1
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Key

/// Shudo's key in the well: the pad-grid mark on a walnut disc with a fine
/// metal edge, pressed down while touched. While recording it becomes the
/// Pernambuco send arrow, a spinner while transcribing, retry after a failed
/// upload — always the same spot.
struct CommandKey: View {
    let role: CaptureLeadingRole
    var isPressed = false
    var hasDraft = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var diameter: CGFloat { CommandBandMetrics.keyDiameter }

    var body: some View {
        ZStack {
            if role == .mic {
                CoachAvatar(size: diameter)
                    .transition(.opacity)
            } else {
                face
                    .transition(.opacity)
            }
        }
        .frame(width: diameter, height: diameter)
        .overlay {
            // The key's machined edge, the same metal as the rim.
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [Color(hex: 0xE6DCCD).opacity(0.38), Color(hex: 0xE6DCCD).opacity(0.06)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.75
                )
        }
        .overlay(alignment: .topTrailing) {
            if hasDraft, role == .mic {
                Circle()
                    .fill(Design.Color.pernambuco)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(Design.Color.canvas, lineWidth: 2))
                    .offset(x: -3, y: 3)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .shadow(color: .black.opacity(isPressed ? 0.2 : 0.55), radius: isPressed ? 1 : 5, y: isPressed ? 0 : 2)
        .scaleEffect(isPressed && !reduceMotion ? 0.94 : 1)
        .brightness(isPressed ? -0.06 : 0)
        .animation(Design.Motion.snap, value: isPressed)
        .animation(Design.Motion.calm(Design.Motion.snap, reduceMotion: reduceMotion), value: role)
        .animation(Design.Motion.calm(Design.Motion.snap, reduceMotion: reduceMotion), value: hasDraft)
        .contentShape(Circle())
    }

    private var face: some View {
        ZStack {
            Circle().fill(Design.Color.emberFill)
            if role == .working {
                ProgressView()
                    .controlSize(.small)
                    .tint(Design.Color.onEmber)
            } else {
                Image(systemName: role.symbol)
                    .font(.custom(Design.Typeface.faceName(.bold), fixedSize: diameter * 0.36))
                    .fontWeight(.semibold)
                    .foregroundStyle(Design.Color.onEmber)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
    }
}
