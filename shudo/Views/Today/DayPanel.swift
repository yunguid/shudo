import SwiftUI

// MARK: - The sheet

/// The open day: a sheet of the same paper drawn down from under the
/// header's strokes. `progress` runs 0 (shut) to 1 (open); past 1 is a
/// finger pulling further, and the sheet gives a little. The edge moves,
/// not the contents — the macros and meals already sit where they'll rest,
/// and the edge uncovers them top to bottom with the ink clearing a beat
/// behind the paper, so nothing is ever drawn over bare thread. The
/// lamplight stays fixed to the screen, so the paper is one page with the
/// header above it.
struct DayPanelSheet<Content: View>: View, Animatable {
    var progress: CGFloat
    /// The sheet's top, measured from the top of the screen.
    let top: CGFloat
    let reduceMotion: Bool
    @ViewBuilder var content: Content

    /// The paper's soft edge, where the thread shows through again.
    static var fade: CGFloat { 26 }
    /// Solid paper the ink keeps between itself and that edge.
    static var lead: CGFloat { 18 }

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        // Reduce Motion: no edge travelling down. The paper fades in first
        // and the parts ink in on it (PanelInk), so the thread and the day
        // never show through each other.
        let reveal = reduceMotion ? 1 : min(max(progress, 0), 1)
        // Shut, the day isn't there at all. Masked in place it would still
        // lie over the thread for touch, VoiceOver and UI tests, so nothing
        // in the thread below the header could be reached. Keyed to the
        // animated progress, the fold still plays out to the last frame.
        if progress > 0 {
            content
                .mask(alignment: .top) { ink(reveal: reveal) }
                .modifier(Overpull(progress: reduceMotion ? 1 : progress))
                .background(alignment: .top) {
                    paper(reveal: reveal)
                        .opacity(reduceMotion ? Double(min(max(progress * 2, 0), 1)) : 1)
                }
        }
    }

    /// The ink: fully there above the edge, cleared `lead` points before it.
    private func ink(reveal: CGFloat) -> some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let edge = reveal * (height + Self.lead + Self.fade) - Self.fade
            VStack(spacing: 0) {
                Color.black.frame(height: height + Self.lead)
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: Self.lead)
            }
            // Only the offset moves frame to frame; nothing is laid out again.
            .offset(y: edge - Self.lead - (height + Self.lead))
        }
    }

    /// The paper: the screen's own background, solid down to the edge, then
    /// dissolving into the thread over `fade`. Pulled past open it stretches
    /// with the sheet, so the gap above the meals is paper too.
    private func paper(reveal: CGFloat) -> some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let stretch = reduceMotion ? 0 : max(progress - 1, 0) * height
            let reach = height + Self.lead + Self.fade + stretch
            AppBackground()
                .frame(width: proxy.size.width, height: top + reach)
                .mask(alignment: .top) {
                    VStack(spacing: 0) {
                        Color.black.frame(height: top + reach)
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: Self.fade)
                    }
                    .offset(y: (reveal - 1) * (height + Self.lead + Self.fade) - Self.fade)
                }
                // Hung from the top of the screen so the lamplight lines up.
                .offset(y: -top)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Past open, the sheet follows the finger down by the overpull.
private struct Overpull: GeometryEffect {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 0, y: max(progress - 1, 0) * size.height))
    }
}

extension View {
    /// A list that runs on under a soft bottom edge, so it reads as more.
    func runsOnBelow(_ fade: CGFloat = 22) -> some View {
        mask {
            VStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: fade)
            }
        }
    }
}

/// Everything below a line: the sheet never rises over the strokes.
struct BelowTopEdge: Shape {
    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX - 400, y: rect.minY, width: rect.width + 800, height: rect.height + 4_000))
    }
}

/// One part of the open day inking in on its turn as the sheet unfolds —
/// a soft blur clearing and a few points of settling — and gone again
/// early as it folds, so the day leaves faster than it arrives.
struct PanelInk: ViewModifier, Animatable {
    var progress: CGFloat
    /// Where in the unfolding this part begins to appear (0…1).
    let start: CGFloat
    let reduceMotion: Bool

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let t = min(max((progress - start) / 0.32, 0), 1)
        let ink = t * t * (3 - 2 * t)
        return content
            .opacity(Double(ink))
            .blur(radius: reduceMotion ? 0 : (1 - ink) * 3)
            .offset(y: reduceMotion ? 0 : (1 - ink) * -6)
    }
}

// MARK: - Motion

/// How the sheet answers a finger: where a hold puts it, how it gives past
/// either end, and the settle that carries the finger's speed home on the
/// house's bounce-free springs.
enum DayPanelMotion {
    /// Opening rides the house settle spring, folding away its snap (the
    /// same numbers as `Design.Motion.settle` and `.snap`, as `Spring`s so
    /// they can carry the finger's speed): the day leaves faster than it
    /// arrives.
    static let open = Spring(response: 0.55, dampingRatio: 0.92)
    static let close = Spring(response: 0.32, dampingRatio: 0.9)

    /// Past either end the sheet keeps following, ever more reluctantly —
    /// at most `limit` more of its height, like a scroll view's overscroll.
    static func rubberBand(_ raw: CGFloat, limit: CGFloat = 0.14) -> CGFloat {
        func give(_ over: CGFloat) -> CGFloat { limit * (1 - 1 / (over * 0.55 / limit + 1)) }
        if raw > 1 { return 1 + give(raw - 1) }
        if raw < 0 { return -give(-raw) }
        return raw
    }

    /// A sheet let go while moving goes the way it was going — even an
    /// unhurried push means "away"; one let go at rest goes to the nearer
    /// end. `velocity` is in sheet heights per second.
    static func opens(at progress: CGFloat, velocity: CGFloat) -> Bool {
        if abs(velocity) > 0.3 { return velocity > 0 }
        return progress > 0.5
    }

    /// The finger's speed as the spring's starting speed (SwiftUI counts it
    /// in "whole distances per second"). Only speed toward home carries, and
    /// never more than the spring can absorb without sailing past it.
    static func initialVelocity(_ velocity: CGFloat, from: CGFloat, to: CGFloat, spring: Spring) -> Double {
        let distance = to - from
        guard abs(distance) > 0.01 else { return 0 }
        let ceiling = 0.8 * 2 * Double.pi / spring.response
        return min(max(Double(velocity / distance), 0), ceiling)
    }
}

// MARK: - Macros

/// The day's three macros side by side: what's eaten in a figure readable
/// at a glance, the target small beside it, a stroke beneath. Protein
/// carries the accent; carbs and fat recede. Large text gets one macro to
/// a line.
struct DayMacroTrio: View {
    let totals: DayTotals
    let target: MacroTarget

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(spacing: 11) {
                    MacroBar(label: "Protein", value: totals.proteinG, target: max(target.proteinG, 1), color: Design.Color.macroProtein)
                    MacroBar(label: "Carbs", value: totals.carbsG, target: max(target.carbsG, 1), color: Design.Color.macroCarbs)
                    MacroBar(label: "Fat", value: totals.fatG, target: max(target.fatG, 1), color: Design.Color.macroFat)
                }
            } else {
                HStack(alignment: .top, spacing: Design.Space.l) {
                    column("Protein", totals.proteinG, target.proteinG, color: Design.Color.macroProtein, figure: Design.Color.macroProtein)
                    column("Carbs", totals.carbsG, target.carbsG, color: Design.Color.macroCarbs, figure: Design.Color.textSecondary)
                    column("Fat", totals.fatG, target.fatG, color: Design.Color.macroFat, figure: Design.Color.textSecondary)
                }
            }
        }
        // Figures roll and strokes fill like the header's own.
        .animation(Design.Motion.gated(Design.Motion.ring, reduceMotion: reduceMotion), value: totals)
    }

    private func column(_ label: String, _ value: Double, _ goal: Double, color: Color, figure: Color) -> some View {
        let eaten = Int(value.rounded())
        let target = Int(goal.rounded())
        return VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(Design.Typeface.text(.caption))
                .foregroundStyle(Design.Color.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(eaten.formatted())
                    .font(Design.Typeface.numeral(.title3, weight: .medium))
                    .foregroundStyle(figure)
                    .contentTransition(.numericText(value: Double(eaten)))
                    .animation(Design.Motion.gated(Design.Motion.snap, reduceMotion: reduceMotion), value: eaten)
                Text("/ \(target.formatted()) g")
                    .font(Design.Typeface.numeral(.caption))
                    .foregroundStyle(Design.Color.textTertiary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            DayStroke(progress: DayHeaderMath.progress(value, goal), color: color)
                .padding(.top, 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(eaten) of \(target) grams")
    }
}

// MARK: - Meals

/// One meal in the open day, read at a glance: what it was and when on the
/// left, its calories and protein lined up on the right — and its photo in
/// the margin when it has one.
struct DayMealRow: View {
    let meal: Entry
    let time: String
    /// Some meal today has a photo: every row keeps the margin so the names
    /// line up.
    var keepsPhotoMargin = false

    @Environment(\.dynamicTypeSize) private var typeSize

    private var isSettled: Bool { meal.status == .complete }

    var body: some View {
        HStack(alignment: .center, spacing: Design.Space.m) {
            if keepsPhotoMargin, !typeSize.isAccessibilitySize {
                Group {
                    if let url = meal.imageURL {
                        MealThumb(url: url)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: MealThumb.side, height: MealThumb.side)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: Design.Space.s) {
                    Text(meal.summary)
                        .font(Design.Typeface.text(.subheadline))
                        .foregroundStyle(isSettled ? Design.Color.textPrimary : Design.Color.textSecondary)
                        .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                    Spacer(minLength: Design.Space.s)
                    calories
                }
                HStack(alignment: .firstTextBaseline, spacing: Design.Space.s) {
                    Text(time)
                        .font(Design.Typeface.numeral(.caption))
                        .foregroundStyle(Design.Color.textTertiary)
                        .lineLimit(1)
                    Spacer(minLength: Design.Space.s)
                    if isSettled { protein }
                }
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var calories: some View {
        switch meal.status {
        case .complete:
            Text(Int(meal.caloriesKcal.rounded()).formatted())
                .font(Design.Typeface.numeral(.subheadline, weight: .semibold))
                .foregroundStyle(Design.Color.textPrimary)
                .lineLimit(1)
                .fixedSize()
        case .failed:
            Text("Not logged")
                .font(Design.Typeface.text(.caption))
                .foregroundStyle(Design.Color.danger)
                .fixedSize()
        default:
            ThreadShimmerLine(width: 34)
        }
    }

    private var protein: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("\(Int(meal.proteinG.rounded())) g")
                .font(Design.Typeface.numeral(.caption, weight: .semibold))
                .foregroundStyle(Design.Color.macroProtein)
            Text(" protein")
                .font(Design.Typeface.text(.caption))
                .foregroundStyle(Design.Color.textTertiary)
        }
        .lineLimit(1)
        .fixedSize()
    }

    private var accessibilityLabel: String {
        switch meal.status {
        case .complete:
            return "\(meal.summary), \(time), \(Int(meal.caloriesKcal.rounded())) kilocalories, \(Int(meal.proteinG.rounded())) grams protein"
        case .failed:
            return "\(meal.summary), \(time), not logged"
        default:
            return "\(meal.summary), \(time), still working on it"
        }
    }
}

/// A meal's photo, small, in the ledger's margin.
struct MealThumb: View {
    static let side: CGFloat = 36
    let url: URL

    var body: some View {
        AsyncImage(url: url, transaction: .init(animation: .easeInOut(duration: 0.2))) { phase in
            if case .success(let image) = phase {
                image.resizable().scaledToFill()
            } else {
                Design.Color.surface2
            }
        }
        .frame(width: Self.side, height: Self.side)
        .clipShape(RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                .strokeBorder(Design.Color.hairline, lineWidth: Design.Stroke.hairline)
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
