import SwiftUI
import UIKit

// MARK: - Photo

/// A check-in photo, loaded through `BodyPhotoLoader` (encrypted disk cache →
/// authenticated download), filling its frame. Shows a quiet placeholder
/// while loading; never uses AsyncImage / URLCache.
struct BodyPhotoImage: View {
    let path: String?
    @ObservedObject var loader: BodyPhotoLoader
    var maxPixel: Int = BodyPhotoSize.thumb

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Design.Color.surface2)
            if let image = image ?? path.flatMap({ loader.cachedImage(path: $0, maxPixel: maxPixel) }) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else if path != nil {
                ProgressView().controlSize(.small).tint(Design.Color.textTertiary)
            }
        }
        .clipped()
        .task(id: path) {
            guard let path else { image = nil; return }
            if let cached = loader.cachedImage(path: path, maxPixel: maxPixel) {
                image = cached
                return
            }
            let loaded = await loader.image(path: path, maxPixel: maxPixel)
            withAnimation(Design.Motion.breath) { image = loaded }
        }
        .accessibilityHidden(true)
    }
}

/// Privacy veil: physique photos stay blurred until revealed for the session.
/// `iconSize: nil` drops the eye glyph (a row of tiles doesn't need twelve).
struct PhysiqueVeil: ViewModifier {
    let isRevealed: Bool
    var iconSize: Font? = .footnote

    func body(content: Content) -> some View {
        content
            .blur(radius: isRevealed ? 0 : 18, opaque: true)
            .overlay {
                if !isRevealed {
                    ZStack {
                        Design.Color.canvas.opacity(0.3)
                        if let iconSize {
                            Image(systemName: "eye.slash")
                                .font(iconSize)
                                .foregroundStyle(Design.Color.textSecondary)
                        }
                    }
                    .transition(.opacity)
                }
            }
            .animation(Design.Motion.breath, value: isRevealed)
    }
}

extension View {
    func physiqueVeil(revealed: Bool, iconSize: Font? = .footnote) -> some View {
        modifier(PhysiqueVeil(isRevealed: revealed, iconSize: iconSize))
    }
}

// MARK: - Type at sizes the text styles don't reach

/// Still the app's one face (`Design.Typeface`), at the two sizes its text
/// styles don't cover: a page's hero figure and tiny fixed labels inside
/// dense graphics.
enum BodyType {
    /// The page's one hero number; scales with Dynamic Type from `.largeTitle`.
    static func hero(_ size: CGFloat, weight: Font.Weight = .light) -> Font {
        .custom(Design.Typeface.faceName(weight), size: size, relativeTo: .largeTitle).monospacedDigit()
    }

    /// Calendar anchors and thumbnail tags: fixed, so a dense grid never reflows.
    static func fixed(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .custom(Design.Typeface.faceName(weight), fixedSize: size)
    }
}

// MARK: - Buttons & placeholders

/// Small capsule actions on the Body page. `prominent` is the accent CTA
/// (flat Pernambuco, sumi ink) and appears at most once; the quiet one is a
/// walnut step with cream ink.
struct BodyPillButtonStyle: ButtonStyle {
    var prominent = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Design.Typeface.text(.subheadline, weight: prominent ? .semibold : .medium))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(prominent ? Design.Color.onEmber : Design.Color.textPrimary)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .background {
                if prominent {
                    Capsule().fill(Design.Color.emberFill)
                } else {
                    Capsule().fill(Design.Color.surface2)
                }
            }
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(Design.Motion.snap, value: configuration.isPressed)
    }
}

/// The empty slot for today's photo: a faint dashed frame and a camera
/// glyph, the shape the photo will take.
struct CheckInPhotoPlaceholder: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
            .fill(Design.Color.surface1)
            .overlay {
                RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                    .strokeBorder(
                        Design.Color.oak.opacity(0.45),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                    )
            }
            .overlay {
                Image(systemName: "camera")
                    .font(Design.Typeface.text(.body))
                    .foregroundStyle(Design.Color.oak)
            }
    }
}

/// A section's name (a small eyebrow) and an optional quiet action.
struct BodyCardHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).eyebrowStyle()
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            trailing
        }
    }
}

// MARK: - Barbell meter

/// Bulk progress as a loaded barbell, drawn quietly: a hairline bar and
/// slim plates, one pair per 2.5 lb between the goal's start and target.
/// Loaded plates are Pernambuco, the plate being earned fills from the
/// floor, the rest are bare walnut.
struct BarbellMeter: View {
    let gainedPounds: Double
    let goalPounds: Double
    static let poundsPerPlate = 2.5

    static func slots(goalPounds: Double) -> Int {
        min(max(Int((abs(goalPounds) / poundsPerPlate).rounded(.up)), 1), 8)
    }

    /// 0…slots plates earned (fractional for the plate in progress).
    static func filled(gainedPounds: Double, goalPounds: Double) -> Double {
        guard goalPounds != 0 else { return 0 }
        let fraction = min(max(gainedPounds / goalPounds, 0), 1)
        return fraction * Double(slots(goalPounds: goalPounds))
    }

    private static let plateWidth: CGFloat = 8
    private static let plateSpacing: CGFloat = 3

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The plates load once when the meter first appears.
    @State private var loaded = false

    var body: some View {
        let slots = Self.slots(goalPounds: goalPounds)
        let filled = Self.filled(gainedPounds: gainedPounds, goalPounds: goalPounds) * (loaded || reduceMotion ? 1 : 0)
        GeometryReader { geo in
            let height = geo.size.height
            ZStack {
                // The bar, its sleeves running a touch past the plates.
                Capsule()
                    .fill(Design.Color.hinoki.opacity(0.18))
                    .frame(height: 2)
                HStack(spacing: 0) {
                    plates(slots: slots, filled: filled, reversed: true, height: height)
                    collar(height: height)
                    Spacer(minLength: 0)
                    collar(height: height)
                    plates(slots: slots, filled: filled, reversed: false, height: height)
                }
                .padding(.horizontal, 10)
            }
            .frame(maxHeight: .infinity)
        }
        .onAppear {
            guard !loaded else { return }
            withAnimation(Design.Motion.gated(Design.Motion.ring.delay(0.15), reduceMotion: reduceMotion)) {
                loaded = true
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Barbell meter: \(BodyUnits.format(max(gainedPounds, 0))) of \(BodyUnits.format(abs(goalPounds))) pounds, \(Int(Self.filled(gainedPounds: gainedPounds, goalPounds: goalPounds))) of \(slots) plates loaded"
        )
    }

    private func collar(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(Design.Color.hinoki.opacity(0.22))
            .frame(width: 3, height: height * 0.3)
            .padding(.horizontal, 3)
    }

    /// Heaviest plates sit innermost, stepping down toward the sleeve ends.
    private func plates(slots: Int, filled: Double, reversed: Bool, height: CGFloat) -> some View {
        let order = reversed ? Array((0..<slots).reversed()) : Array(0..<slots)
        return HStack(spacing: Self.plateSpacing) {
            ForEach(order, id: \.self) { index in
                let amount = min(max(filled - Double(index), 0), 1)
                let plateHeight = height * (1 - CGFloat(min(index, 4)) * 0.1)
                ZStack(alignment: .bottom) {
                    Rectangle().fill(Design.Color.surface3)
                    Rectangle()
                        .fill(Design.Color.pernambuco)
                        .frame(height: plateHeight * amount)
                }
                .frame(width: Self.plateWidth, height: plateHeight)
                .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
            }
        }
    }
}

// MARK: - Pace

extension PaceStatus {
    /// The one-word verdict next to the rate; nil when there's no judgment
    /// to make (no goal, or not enough data), so the line shows the rate alone.
    var label: String? {
        switch self {
        case .onPace: "on pace"
        case .ahead: "ahead"
        case .behind: "behind"
        case .stalled: "stalled"
        case .wrongDirection: "wrong way"
        case .tooFast: "too fast"
        case .drifting: "drifting"
        case .goalReached: "goal hit"
        case .insufficientData, .noGoal: nil
        }
    }

    var color: Color {
        switch self {
        case .onPace, .ahead: Design.Color.positive
        case .goalReached: Design.Color.ember
        case .behind, .stalled, .tooFast, .drifting: Design.Color.warning
        case .wrongDirection: Design.Color.danger
        case .insufficientData, .noGoal: Design.Color.textTertiary
        }
    }
}

enum BodyDayLabel {
    private static let short: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    static func short(_ localDay: String) -> String {
        LocalDayMath.date(localDay).map { short.string(from: $0) } ?? localDay
    }

    @MainActor
    static func time(_ date: Date, timezone: String) -> String {
        Design.Clock.short(date, timeZone: TimeZone(identifier: timezone) ?? .autoupdatingCurrent)
    }
}
