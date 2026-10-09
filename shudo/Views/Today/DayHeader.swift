import SwiftUI

/// The top of the day, written like a diary page: the day's name in serif
/// (tap it for the calendar), where Luke is in the phase, and one figure —
/// kcal left — over two brushstrokes, calories and protein. Nothing boxed.
///
/// Tap (or pull down on) the figure and the day unfolds beneath it like a
/// shoji panel sliding open: the macro breakdown, the meal ledger (tap to
/// open, swipe to delete with undo), and the week. What was already on
/// screen stays exactly where it was; only the panel moves. At accessibility
/// text sizes the trailing numbers drop under the figure and the open day
/// scrolls in place.
struct DayHeader<Account: View, DayPicker: View>: View {
    @Binding var expanded: Bool
    @Binding var isPickingDay: Bool
    /// "Today", "Yesterday", "Monday", "Mon, Sep 28".
    let title: String
    /// "Day 35 of the bulk", or "typing…" while Shudo answers.
    let subtitle: String?
    var subtitleIsLive = false
    let numbers: DayHeaderNumbers
    let totals: DayTotals
    let target: MacroTarget
    let weekDays: [WeekStripDay]
    /// The day's meals, oldest first.
    let meals: [Entry]
    let timeText: (Date) -> String
    var onSelectDay: (String) -> Void
    var onOpenMeal: (Entry) -> Void
    var onDeleteMeal: (Entry) -> Void
    var onOpenInsights: () -> Void
    let zoomNamespace: Namespace.ID
    /// A finished day in the diary: what's left reads as "short".
    var isPast = false
    @ViewBuilder var account: Account
    @ViewBuilder var dayPicker: DayPicker

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    /// How far the canvas behind the header dissolves into the thread.
    private let fade: CGFloat = 26

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleRow
            Group {
                if expanded, typeSize.isAccessibilitySize {
                    ScrollView { day }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(maxHeight: 520)
                } else {
                    day
                }
            }
        }
        .padding(.horizontal, Design.Space.gutter)
        .padding(.top, Design.Space.xs)
        .padding(.bottom, Design.Space.s)
        .background(alignment: .top) { backdrop }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today.header")
    }

    // MARK: Title

    private var titleRow: some View {
        HStack(alignment: .center, spacing: Design.Space.m) {
            Button {
                isPickingDay = true
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        // A shoji hand-off, never a blend: the old day's name
                        // is gone quickly, the new one settles in like ink.
                        ZStack(alignment: .leading) {
                            Text(title)
                                .font(Design.Typeface.display(.title2))
                                .foregroundStyle(Design.Color.textPrimary)
                                .lineLimit(1)
                                .id(title)
                                .transition(.inkHandoff(reduceMotion: reduceMotion))
                        }
                        .animation(Design.Motion.calm(Design.Motion.settle, reduceMotion: reduceMotion), value: title)
                        Image(systemName: "chevron.down")
                            .font(Design.Typeface.text(.caption2, weight: .semibold))
                            .foregroundStyle(Design.Color.textTertiary)
                            .accessibilityHidden(true)
                    }
                    if let subtitle {
                        Text(subtitle)
                            .font(Design.Typeface.text(.caption))
                            .foregroundStyle(subtitleIsLive ? Design.Color.ember : Design.Color.textTertiary)
                            .lineLimit(1)
                            .contentTransition(.opacity)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isPickingDay, arrowEdge: .top) { dayPicker }
            .animation(Design.Motion.calm(Design.Motion.breath, reduceMotion: reduceMotion), value: subtitle)
            .accessibilityLabel(title)
            .accessibilityValue(subtitle ?? "")
            .accessibilityHint("Pick a day")
            .accessibilityIdentifier("today.day")

            Spacer(minLength: 0)
            account
        }
        .frame(minHeight: 44)
    }

    // MARK: The day

    private var day: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                figureRow
                    .padding(.top, Design.Space.l)
                meter
                    .padding(.top, Design.Space.m)
            }
            .contentShape(Rectangle())
            // Pull on the figure, not the ledger, so scrolling a long day
            // never folds the panel; large text scrolls instead.
            .simultaneousGesture(pull, including: typeSize.isAccessibilitySize ? .subviews : .all)
            // The panel has its own clipped well, so it slides out from
            // under the strokes and never passes over the figure.
            VStack(spacing: 0) {
                if expanded {
                    unfolded
                        .transition(unfold)
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .clipped()
        }
        .contentShape(Rectangle())
        .onTapGesture { toggle() }
    }

    /// "855 kcal left" with the macros at the trailing edge; open, the
    /// trailing edge names the target instead and the macros move below.
    private var figureRow: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Design.Space.s))
            : AnyLayout(HStackLayout(alignment: .lastTextBaseline, spacing: Design.Space.m))
        return layout {
            remaining
            if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
            ZStack(alignment: typeSize.isAccessibilitySize ? .leading : .trailing) {
                if expanded {
                    Text("of \(numbers.targetKcal.formatted()) kcal")
                        .font(Design.Typeface.numeral(.footnote))
                        .monospacedDigit()
                        .foregroundStyle(Design.Color.textTertiary)
                        .transition(.inkHandoff(reduceMotion: reduceMotion))
                } else {
                    macroSummary
                        .transition(.inkHandoff(reduceMotion: reduceMotion))
                }
            }
            .accessibilityHidden(true)
        }
    }

    /// The hero number: serif, quiet weight, alone.
    private var remaining: some View {
        let value = numbers.isOver ? numbers.overKcal : numbers.remainingKcal
        return HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(value.formatted())
                .font(Design.Typeface.figure(.largeTitle, weight: .light))
                .monospacedDigit()
                .foregroundStyle(Design.Color.textPrimary)
                .contentTransition(.numericText(value: Double(value)))
                .animation(Design.Motion.gated(Design.Motion.snap, reduceMotion: reduceMotion), value: value)
                .lineLimit(1)
                .fixedSize()
            Text(DayHeaderMath.remainingLabel(numbers, isPast: isPast))
                .font(Design.Typeface.text(.subheadline))
                .foregroundStyle(numbers.isOver ? Design.Color.honey : Design.Color.textSecondary)
                .lineLimit(1)
                .fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(expanded ? "Folds the day away" : "Shows your macros, meals and the week")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { toggle() }
        .accessibilityIdentifier("today.header.remaining")
    }

    /// Protein is the one accented metric; carbs and fat recede.
    private var macroSummary: some View {
        VStack(alignment: typeSize.isAccessibilitySize ? .leading : .trailing, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(Int(totals.proteinG.rounded()).formatted())
                    .font(Design.Typeface.numeral(.subheadline, weight: .semibold))
                    .foregroundStyle(Design.Color.macroProtein)
                Text("g protein")
                    .font(Design.Typeface.text(.caption))
                    .foregroundStyle(Design.Color.textTertiary)
            }
            Text("\(Int(totals.carbsG.rounded())) C  ·  \(Int(totals.fatG.rounded())) F")
                .font(Design.Typeface.numeral(.caption))
                .foregroundStyle(Design.Color.textTertiary)
        }
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
    }

    private var accessibilityLabel: String {
        let calories = numbers.isOver
            ? "\(numbers.overKcal) kilocalories over \(numbers.targetKcal)"
            : "\(numbers.remainingKcal) kilocalories \(isPast ? "short" : "left") of \(numbers.targetKcal)"
        return "\(calories). \(Int(totals.proteinG.rounded())) of \(Int(target.proteinG.rounded())) grams protein"
    }

    /// Two brushstrokes: calories in hinoki, protein in Pernambuco. Open,
    /// protein joins carbs and fat in the breakdown below.
    private var meter: some View {
        VStack(spacing: 5) {
            DayStroke(progress: numbers.kcalProgress, color: Design.Color.macroKcal)
            if !expanded {
                DayStroke(progress: numbers.proteinProgress, color: Design.Color.macroProtein)
                    .transition(.opacity)
            }
        }
        .animation(Design.Motion.gated(Design.Motion.ring, reduceMotion: reduceMotion), value: numbers)
        .accessibilityHidden(true)
    }

    // MARK: Unfolded

    private var unfolded: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 11) {
                MacroBar(label: "Protein", value: totals.proteinG, target: max(target.proteinG, 1), color: Design.Color.macroProtein)
                MacroBar(label: "Carbs", value: totals.carbsG, target: max(target.carbsG, 1), color: Design.Color.macroCarbs)
                MacroBar(label: "Fat", value: totals.fatG, target: max(target.fatG, 1), color: Design.Color.macroFat)
            }
            .padding(.top, Design.Space.xl)

            if !meals.isEmpty {
                ledger
                    .padding(.top, Design.Space.xl)
            }

            WeekStrip(days: weekDays, onSelect: onSelectDay)
                .padding(.top, Design.Space.xl)
            insightsLink
                .padding(.top, Design.Space.xs)
        }
    }

    /// A panel drawn out from under the strokes, weighted, no bounce.
    private var unfold: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .move(edge: .top).combined(with: .opacity),
                removal: .move(edge: .top).combined(with: .opacity)
            )
    }

    private func toggle() {
        withAnimation(Design.Motion.calm(Design.Motion.shoji, reduceMotion: reduceMotion)) {
            expanded.toggle()
        }
    }

    /// Pull down to open the day, push up to fold it away.
    private var pull: some Gesture {
        DragGesture(minimumDistance: 18)
            .onEnded { value in
                let vertical = value.translation.height
                guard abs(vertical) > abs(value.translation.width) * 1.5 else { return }
                if vertical > 36, !expanded { toggle() }
                if vertical < -36, expanded { toggle() }
            }
    }

    // MARK: Backdrop

    /// The page itself, not a card: the same lamplit canvas as the screen,
    /// dissolving into the thread over a short fade so messages pass
    /// beneath it like ink under washi.
    private var backdrop: some View {
        AppBackground()
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                        .frame(height: fade)
                }
                .ignoresSafeArea(edges: .top)
            }
            .padding(.bottom, -fade)
            .allowsHitTesting(false)
    }

    // MARK: Ledger

    /// The day's meals, one line each (tap to open, swipe to delete — no
    /// need to say so). Rows are separated by space, not rules.
    private var ledger: some View {
        Group {
            if meals.count <= 6 || typeSize.isAccessibilitySize {
                ledgerRows
            } else {
                // A long day scrolls inside the panel instead of pushing
                // the thread off screen.
                ScrollView { ledgerRows }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(height: 260)
            }
        }
    }

    private var ledgerRows: some View {
        VStack(spacing: 0) {
            ForEach(meals) { meal in
                LedgerSwipeRow(onDelete: { onDeleteMeal(meal) }, canDelete: meal.canDelete) {
                    ledgerRow(meal)
                }
            }
        }
    }

    private func ledgerRow(_ meal: Entry) -> some View {
        Button {
            onOpenMeal(meal)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Design.Space.m) {
                Text(timeText(meal.createdAt).replacingOccurrences(of: " AM", with: "").replacingOccurrences(of: " PM", with: ""))
                    .font(Design.Typeface.numeral(.caption))
                    .monospacedDigit()
                    .foregroundStyle(Design.Color.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(minWidth: 34, alignment: .leading)
                Text(meal.summary)
                    .font(Design.Typeface.text(.subheadline))
                    .foregroundStyle(meal.status == .complete ? Design.Color.textPrimary : Design.Color.textSecondary)
                    .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                Spacer(minLength: Design.Space.s)
                ledgerTrailing(meal)
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .matchedTransitionSource(id: TodayRoute.zoomID(meal.id, from: .ledger), in: zoomNamespace)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ledger.\(meal.id.uuidString)")
    }

    @ViewBuilder
    private func ledgerTrailing(_ meal: Entry) -> some View {
        switch meal.status {
        case .complete:
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(Int(meal.proteinG.rounded())) P")
                    .font(Design.Typeface.numeral(.caption))
                    .foregroundStyle(Design.Color.macroProtein)
                Text(Int(meal.caloriesKcal.rounded()).formatted())
                    .font(Design.Typeface.numeral(.subheadline, weight: .semibold))
                    .foregroundStyle(Design.Color.textPrimary)
                    .frame(minWidth: 36, alignment: .trailing)
            }
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
        case .failed:
            Text("Not logged")
                .font(Design.Typeface.text(.caption))
                .foregroundStyle(Design.Color.danger)
                .fixedSize()
        default:
            ThreadShimmerLine(width: 36)
        }
    }

    private var insightsLink: some View {
        Button(action: onOpenInsights) {
            HStack(spacing: 6) {
                Text("This week")
                    .font(Design.Typeface.text(.footnote, weight: .medium))
                    .foregroundStyle(Design.Color.textSecondary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(Design.Typeface.text(.caption2, weight: .semibold))
                    .foregroundStyle(Design.Color.textTertiary)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("This week")
        .accessibilityHint("Protein, weekly patterns and the protein guide")
    }
}

/// One brushstroke of progress: a hairline track and a filled length, the
/// width of the page.
struct DayStroke: View {
    let progress: Double
    let color: Color
    var thickness: CGFloat = 2.5

    var body: some View {
        GeometryReader { geometry in
            Capsule()
                .fill(color.opacity(0.13))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(color)
                        .frame(width: progress > 0 ? max(thickness, geometry.size.width * min(progress, 1)) : 0)
                }
        }
        .frame(height: thickness)
    }
}

/// Swipe left to reveal Delete (or swipe all the way to delete). Long-press
/// and VoiceOver get the same action.
struct LedgerSwipeRow<Content: View>: View {
    let onDelete: () -> Void
    var canDelete = true
    @ViewBuilder var content: Content

    @State private var settled: CGFloat = 0
    @GestureState private var drag: CGFloat = 0
    private let revealWidth: CGFloat = 76

    private var offset: CGFloat { min(0, settled + drag) }

    var body: some View {
        ZStack(alignment: .trailing) {
            if canDelete, offset < -4 {
                Button(role: .destructive) {
                    withAnimation(Design.Motion.snap) { settled = 0 }
                    onDelete()
                } label: {
                    Image(systemName: "trash.fill")
                        .font(Design.Typeface.text(.body, weight: .semibold))
                        .foregroundStyle(Design.Color.textPrimary)
                        .frame(width: max(revealWidth, -offset))
                        .frame(maxHeight: .infinity)
                        .background(Design.Color.danger, in: RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete meal")
            }
            content
                .background(Design.Color.canvas.opacity(offset < 0 ? 1 : 0))
                .offset(x: offset)
        }
        .clipped()
        // High priority: a real swipe (≥20 pt) must cancel the row's tap,
        // or lifting the finger would also open the meal.
        .highPriorityGesture(swipe, including: canDelete ? .all : .subviews)
        .contextMenu {
            if canDelete {
                Button("Delete meal", systemImage: "trash", role: .destructive, action: onDelete)
            }
        }
        .accessibilityAction(named: "Delete meal") { if canDelete { onDelete() } }
        .animation(Design.Motion.snap, value: settled)
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 20)
            .updating($drag) { value, state, _ in
                guard abs(value.translation.width) > abs(value.translation.height) * 1.4 else { return }
                state = value.translation.width
            }
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) * 1.4 else { return }
                let final = settled + value.translation.width
                if final < -170 || value.predictedEndTranslation.width < -320 {
                    settled = 0
                    onDelete()
                } else if final < -36 {
                    settled = -revealWidth
                } else {
                    settled = 0
                }
            }
    }
}

/// The week under the day: a letter and a small pair of rings per day. The
/// selected day carries one Pernambuco mark beneath it; no pills.
struct WeekStrip: View {
    let days: [WeekStripDay]
    var onSelect: (String) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(days) { day in
                Button {
                    onSelect(day.localDay)
                } label: {
                    VStack(spacing: 7) {
                        Text(day.letter)
                            .font(Design.Typeface.text(.caption2, weight: day.isSelected ? .semibold : .medium))
                            .foregroundStyle(letterColor(day))
                        MacroRings(kcal: day.kcalProgress, protein: day.proteinProgress, size: 24, lineWidth: 2.5)
                            .opacity(day.isFuture ? 0.25 : (day.hasLog || day.isSelected ? 1 : 0.5))
                        Circle()
                            .fill(Design.Color.ember)
                            .frame(width: 4, height: 4)
                            .opacity(day.isSelected ? 1 : 0)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(day.isFuture)
                .accessibilityLabel(accessibilityLabel(day))
                .accessibilityAddTraits(day.isSelected ? .isSelected : [])
            }
        }
    }

    private func letterColor(_ day: WeekStripDay) -> Color {
        if day.isSelected { return Design.Color.textPrimary }
        if day.isToday { return Design.Color.textSecondary }
        return Design.Color.textTertiary
    }

    private func accessibilityLabel(_ day: WeekStripDay) -> String {
        let name = ThreadCardCopy.weekdayName(day.localDay, short: false) ?? day.localDay
        if day.isFuture { return name }
        return "\(name), \(Int((day.kcalProgress * 100).rounded())) percent of calories"
    }
}
