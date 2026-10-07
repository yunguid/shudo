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
            withAnimation(.easeOut(duration: 0.2)) { image = loaded }
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
                        Design.Color.canvas.opacity(0.25)
                        if let iconSize {
                            Image(systemName: "eye.slash.fill")
                                .font(iconSize.weight(.semibold))
                                .foregroundStyle(Design.Color.textSecondary)
                        }
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: isRevealed)
    }
}

extension View {
    func physiqueVeil(revealed: Bool, iconSize: Font? = .footnote) -> some View {
        modifier(PhysiqueVeil(isRevealed: revealed, iconSize: iconSize))
    }
}

// MARK: - Buttons & placeholders

struct BodyPillButtonStyle: ButtonStyle {
    var prominent = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(prominent ? Design.Color.onEmber : Design.Color.textPrimary)
            .padding(.horizontal, 14)
            .frame(minHeight: 38)
            .background {
                if prominent {
                    Capsule().fill(Design.Color.emberFill)
                } else {
                    Capsule().fill(Design.Color.surface3)
                }
            }
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
    }
}

/// The empty slot for today's photo: dashed ember outline + viewfinder.
struct CheckInPhotoPlaceholder: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Design.Color.surface2)
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        Design.Color.ember.opacity(0.8),
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                    )
            }
            .overlay {
                Image(systemName: "camera.viewfinder")
                    .font(.title.weight(.semibold))
                    .foregroundStyle(Design.Color.ember)
            }
    }
}

struct BodyCardHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).eyebrowStyle()
            Spacer(minLength: 8)
            trailing
        }
    }
}

// MARK: - Barbell meter

/// Bulk progress as a loaded barbell: one plate pair per 2.5 lb between the
/// goal's start and target. Full plates glow ember, the plate being earned
/// is a dashed outline, the rest are bare iron.
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

    var body: some View {
        let slots = Self.slots(goalPounds: goalPounds)
        let filled = Self.filled(gainedPounds: gainedPounds, goalPounds: goalPounds)
        GeometryReader { geo in
            let mid = geo.size.height / 2
            let plateWidth = min(14, max(8, (geo.size.width / 2 - 40) / CGFloat(slots) - 4))
            ZStack {
                Capsule()
                    .fill(LinearGradient(
                        colors: [Color(hex: 0x8C857A), Color(hex: 0x4A453F)],
                        startPoint: .top, endPoint: .bottom))
                    .frame(height: 7)
                    .position(x: geo.size.width / 2, y: mid)
                HStack(spacing: 4) {
                    plates(slots: slots, filled: filled, reversed: true, width: plateWidth, height: geo.size.height)
                    Spacer(minLength: 0)
                    plates(slots: slots, filled: filled, reversed: false, width: plateWidth, height: geo.size.height)
                }
                .padding(.horizontal, 18)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Barbell meter: \(BodyUnits.format(max(gainedPounds, 0))) of \(BodyUnits.format(abs(goalPounds))) pounds, \(Int(filled)) of \(slots) plates loaded"
        )
    }

    private func plates(
        slots: Int, filled: Double, reversed: Bool, width: CGFloat, height: CGFloat
    ) -> some View {
        let order = reversed ? Array((0..<slots).reversed()) : Array(0..<slots)
        return HStack(spacing: 4) {
            ForEach(order, id: \.self) { index in
                let amount = min(max(filled - Double(index), 0), 1)
                let scale = 1 - CGFloat(min(index, 4)) * 0.11
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(amount >= 1 ? AnyShapeStyle(Design.Color.emberFill) : AnyShapeStyle(Design.Color.surface2))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .stroke(
                                amount > 0 && amount < 1 ? Design.Color.ember : Design.Color.hairline,
                                style: StrokeStyle(lineWidth: 1, dash: amount > 0 && amount < 1 ? [3, 2] : []))
                    )
                    .frame(width: width, height: height * scale)
                    .shadow(color: amount >= 1 ? Design.Color.ember.opacity(0.45) : .clear, radius: 5)
            }
        }
    }
}

// MARK: - Pace

extension PaceStatus {
    var label: String {
        switch self {
        case .onPace: "on pace"
        case .ahead: "ahead"
        case .behind: "behind"
        case .stalled: "stalled"
        case .wrongDirection: "wrong way"
        case .tooFast: "too fast"
        case .drifting: "drifting"
        case .goalReached: "goal hit"
        case .insufficientData: "need weigh-ins"
        case .noGoal: "no goal"
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

    static func time(_ date: Date, timezone: String) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: timezone) ?? .autoupdatingCurrent
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }
}
