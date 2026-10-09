import SwiftUI
import UIKit

// MARK: - The command band
//
// The bottom of the app is one reserved band: on the left, a well milled out
// of the screen's bottom-left corner with Shudo's key seated in it (tap to
// talk, hold for the dial); on the right, the tab bar. The band is opaque and
// the shell pads every tab's safe area by its height (`shellBandInset`), so
// nothing — text, icons, cards, the thread's last message — tangles with it.

/// Geometry of the command band. The well is flush with the screen's
/// bottom-left corner; the key fills it but for one small, even margin, its
/// outer corner concentric with the display's own and its other corners
/// concentric with the well's.
struct CommandBandMetrics: Equatable {
    /// The key's side, before the display corner asks for more.
    static let keySide: CGFloat = 76
    /// The key's three inner corners (continuous).
    static let keyCorner: CGFloat = 20
    /// The one small, even margin between the key and everything around it:
    /// the rim, the screen edges, the display corner.
    static let margin: CGFloat = 5
    /// The tab bar's (and the recording strip's) height.
    static let barHeight: CGFloat = 54
    /// Well → tab bar.
    static let barGap: CGFloat = 10
    static let trailingMargin: CGFloat = 16
    /// Breathing room between the content above and the well's lip; content
    /// scrolling down into it dissolves before it reaches the lip.
    static let topGap: CGFloat = 16

    /// Screen display corner radius (0 on square-cornered screens).
    let displayCornerRadius: CGFloat
    /// The window's bottom safe-area inset (home indicator).
    let bottomSafeArea: CGFloat

    /// The key's outer (bottom-left) corner: concentric with the display.
    var keyOuterCorner: CGFloat { max(Self.keyCorner, displayCornerRadius - Self.margin) }
    /// Big enough that the outer corner and an inner corner never meet.
    var keySide: CGFloat { max(Self.keySide, keyOuterCorner + Self.keyCorner + 2) }
    /// The well: the key plus the margin on every side.
    var wellSide: CGFloat { keySide + Self.margin * 2 }
    /// The well's inner corner, concentric with the key's.
    var wellCornerRadius: CGFloat { Self.keyCorner + Self.margin }
    /// The key's center, from the left and the bottom screen edges.
    var keyCenterInset: CGFloat { Self.margin + keySide / 2 }

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

/// The well's outline: the screen's bottom-left corner milled out to a
/// square with a rounded inner corner. `rect` is the full band; its left
/// and bottom edges are the screen's.
struct CommandWellShape: Shape {
    var side: CGFloat
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let top = rect.maxY - side
        let right = rect.minX + side
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: top))
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

/// Just the visible edge of the well — lip, inner corner, wall — open at
/// the screen edges, for the machined rim.
struct CommandWellRim: Shape {
    var side: CGFloat
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let top = rect.maxY - side
        let right = rect.minX + side
        path.move(to: CGPoint(x: rect.minX, y: top))
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

/// The milled corner: a recess stepped down toward sumi black, shaded under
/// its lip and along its wall, edged with a fine warm-titanium chamfer that
/// catches the lamplight along the lip and falls off down the wall. Drawn in
/// the band's frame; the display's own rounded corner finishes the outside.
struct CommandWell: View {
    let metrics: CommandBandMetrics

    private static let recessTop = Color(hex: 0x040302)
    private static let recessBottom = Color(hex: 0x080605)
    /// Warm titanium: hinoki with most of the colour drawn out of it.
    static let metal = Color(hex: 0xE9DFD0)

    var body: some View {
        let side = metrics.wellSide
        let radius = metrics.wellCornerRadius
        let shape = CommandWellShape(side: side, cornerRadius: radius)
        let rim = CommandWellRim(side: side, cornerRadius: radius)
        GeometryReader { proxy in
            let size = proxy.size
            let height = max(size.height, 1)
            let width = max(size.width, 1)
            let top = (size.height - side) / height
            ZStack {
                shape.fill(
                    LinearGradient(
                        colors: [Self.recessTop, Self.recessBottom],
                        startPoint: UnitPoint(x: 0.5, y: top),
                        endPoint: .bottom
                    )
                )
                // Shadow under the lip.
                shape.fill(
                    LinearGradient(
                        colors: [.black.opacity(0.75), .black.opacity(0)],
                        startPoint: UnitPoint(x: 0.5, y: top),
                        endPoint: UnitPoint(x: 0.5, y: top + 9 / height)
                    )
                )
                // And a softer one along the wall.
                shape.fill(
                    LinearGradient(
                        colors: [.black.opacity(0), .black.opacity(0.45)],
                        startPoint: UnitPoint(x: (side - 8) / width, y: 0.5),
                        endPoint: UnitPoint(x: side / width, y: 0.5)
                    )
                )
                // The chamfer's outer facet: a whisper of light on the canvas
                // side of the edge.
                rim.offset(x: 0.75, y: -0.75)
                    .stroke(Self.metal.opacity(0.07), lineWidth: 1)
                // The chamfer itself: bright along the lip, brightest at the
                // inner corner, falling off down the wall; it fades into the
                // bezel at both screen edges.
                rim.stroke(
                    LinearGradient(
                        stops: [
                            .init(color: Self.metal.opacity(0.10), location: 0),
                            .init(color: Self.metal.opacity(0.42), location: 0.1),
                            .init(color: Self.metal.opacity(0.52), location: 0.38),
                            .init(color: Self.metal.opacity(0.62), location: 0.5),
                            .init(color: Self.metal.opacity(0.30), location: 0.64),
                            .init(color: Self.metal.opacity(0.08), location: 0.9),
                            .init(color: Self.metal.opacity(0.03), location: 1),
                        ],
                        startPoint: UnitPoint(x: 0, y: top),
                        endPoint: UnitPoint(x: side / width, y: 1)
                    ),
                    style: StrokeStyle(lineWidth: 1, lineCap: .butt)
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Key

/// The key's outline: three inner corners concentric with the well's, the
/// outer corner concentric with the display's.
struct CommandKeyShape: Shape {
    var corner: CGFloat = CommandBandMetrics.keyCorner
    var outerCorner: CGFloat

    func path(in rect: CGRect) -> Path {
        UnevenRoundedRectangle(
            cornerRadii: RectangleCornerRadii(
                topLeading: corner,
                bottomLeading: outerCorner,
                bottomTrailing: corner,
                topTrailing: corner
            ),
            style: .continuous
        )
        .path(in: rect)
    }
}

/// Shudo's key, seated in the well: the pad-grid mark on a walnut slab with
/// a fine metal edge, pressed down while touched. While recording it becomes
/// the Pernambuco send arrow, a spinner while transcribing, retry after a
/// failed upload — always the same spot.
struct CommandKey: View {
    let role: CaptureLeadingRole
    let metrics: CommandBandMetrics
    var isPressed = false
    var hasDraft = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shape: CommandKeyShape { CommandKeyShape(outerCorner: metrics.keyOuterCorner) }
    /// The slab's visual center sits a little up and in from its box center,
    /// away from the big outer corner.
    private var visualOffset: CGSize { CGSize(width: 2, height: -2) }

    var body: some View {
        ZStack {
            shape.fill(
                RadialGradient(
                    colors: [Color(hex: 0x2B2219), Color(hex: 0x14100C)],
                    center: UnitPoint(x: 0.55, y: 0.3),
                    startRadius: 0,
                    endRadius: metrics.keySide * 0.8
                )
            )
            content
                .offset(visualOffset)
        }
        .frame(width: metrics.keySide, height: metrics.keySide)
        .overlay {
            // The key's machined edge, the same metal as the rim.
            shape.stroke(
                LinearGradient(
                    colors: [CommandWell.metal.opacity(0.30), CommandWell.metal.opacity(0.04)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 0.75
            )
        }
        .shadow(color: .black.opacity(isPressed ? 0.15 : 0.5), radius: isPressed ? 0.5 : 3, y: isPressed ? 0 : 1.5)
        .scaleEffect(isPressed && !reduceMotion ? 0.965 : 1)
        .brightness(isPressed ? -0.05 : 0)
        .animation(Design.Motion.snap, value: isPressed)
        .animation(Design.Motion.calm(Design.Motion.snap, reduceMotion: reduceMotion), value: role)
        .animation(Design.Motion.calm(Design.Motion.snap, reduceMotion: reduceMotion), value: hasDraft)
        .contentShape(shape)
    }

    @ViewBuilder
    private var content: some View {
        switch role {
        case .mic:
            CoachAvatar(size: metrics.keySide * 0.66, showsDisc: false)
                .overlay(alignment: .topTrailing) {
                    if hasDraft {
                        Circle()
                            .fill(Design.Color.pernambuco)
                            .frame(width: 8, height: 8)
                            .offset(x: 9, y: -9)
                            .transition(.scale(scale: 0.4).combined(with: .opacity))
                    }
                }
                .transition(.opacity)
        default:
            // Live: a Pernambuco disc on the walnut — send, a spinner while
            // it transcribes, retry after a failed upload.
            ZStack {
                Circle()
                    .fill(Design.Color.emberFill)
                    .shadow(color: Design.Color.heartwood.opacity(0.55), radius: 6, y: 1)
                if role == .working {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Design.Color.onEmber)
                } else {
                    Image(systemName: role.symbol)
                        .font(.custom(Design.Typeface.faceName(.bold), fixedSize: 19))
                        .fontWeight(.semibold)
                        .foregroundStyle(Design.Color.onEmber)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 46, height: 46)
            .transition(.scale(scale: 0.7).combined(with: .opacity))
        }
    }
}
