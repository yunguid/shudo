import SwiftUI

/// The pinned glass header over the day thread. Compact: rings, "855 kcal
/// left", P/C/F bars. Tap to expand (matched geometry) into the week
/// strip, the big rings, and the meal ledger — tap a meal for its detail,
/// swipe it away to delete (with undo). At accessibility text sizes the
/// bars drop under the number and the expanded day scrolls in place.
struct DayHeader: View {
    @Binding var expanded: Bool
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

    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .caption) private var timeWidth: CGFloat = 40

    var body: some View {
        Group {
            if expanded, typeSize.isAccessibilitySize {
                ScrollView { expandedDay }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: 520)
            } else if expanded {
                expandedDay
            } else if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 14) {
                        rings(size: 58)
                        remaining(style: .title)
                        Spacer(minLength: 0)
                    }
                    VStack(spacing: 7) { bars }
                }
            } else {
                HStack(spacing: 14) {
                    rings(size: 58)
                    remaining(style: .title)
                    Spacer(minLength: 0)
                    VStack(spacing: 7) { bars }
                        .frame(width: 136)
                }
            }
        }
        .padding(14)
        .chromeGlass(
            in: RoundedRectangle(cornerRadius: Design.Radius.cardLarge, style: .continuous),
            tint: Design.Color.canvas.opacity(0.55),
            interactive: true
        )
        .contentShape(RoundedRectangle(cornerRadius: Design.Radius.cardLarge, style: .continuous))
        .onTapGesture { toggle() }
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.6), trigger: expanded)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today.header")
    }

    private var expandedDay: some View {
        VStack(spacing: 0) {
            WeekStrip(days: weekDays, onSelect: onSelectDay)
                .padding(.bottom, 14)
                .transition(.opacity.combined(with: .move(edge: .top)))
            VStack(spacing: 16) {
                HStack(spacing: 18) {
                    rings(size: 104)
                    remaining(style: .largeTitle)
                    Spacer(minLength: 0)
                }
                VStack(spacing: 9) { bars }
            }
            ledger
                .padding(.top, 14)
                .transition(.opacity)
        }
    }

    private func toggle() {
        withAnimation(Design.Motion.gated(Design.Motion.settle, reduceMotion: reduceMotion)) {
            expanded.toggle()
        }
    }

    private func rings(size: CGFloat) -> some View {
        MacroRings(kcal: numbers.kcalProgress, protein: numbers.proteinProgress, size: size)
            .matchedGeometryEffect(id: "rings", in: namespace)
            .animation(Design.Motion.gated(Design.Motion.ring, reduceMotion: reduceMotion), value: numbers)
            .accessibilityHidden(true)
    }

    /// The hero number. Compact: "855 kcal left" and nothing else — the
    /// ring already shows how far along the day is. Expanded adds the target.
    private func remaining(style: Font.TextStyle) -> some View {
        let value = numbers.isOver ? numbers.overKcal : numbers.remainingKcal
        return VStack(alignment: .leading, spacing: 2) {
            Text(value.formatted())
                .font(Design.Typeface.numeral(style, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Design.Color.textPrimary)
                .contentTransition(.numericText(value: Double(value)))
                .animation(Design.Motion.gated(Design.Motion.snap, reduceMotion: reduceMotion), value: value)
                .lineLimit(1)
                .fixedSize()
            Text(numbers.isOver ? "kcal over" : "kcal left")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(numbers.isOver ? Design.Color.honey : Design.Color.textSecondary)
                .lineLimit(1)
                .fixedSize()
            if expanded {
                Text("of \(numbers.targetKcal.formatted())")
                    .font(Design.Typeface.numeral(.footnote, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Design.Color.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
                    .transition(.opacity)
            }
        }
        .matchedGeometryEffect(id: "remaining", in: namespace)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            numbers.isOver
                ? "\(numbers.overKcal) kilocalories over \(numbers.targetKcal)"
                : "\(numbers.remainingKcal) kilocalories left of \(numbers.targetKcal)"
        )
        .accessibilityHint(expanded ? "Collapses the day" : "Shows the week and your meals")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { toggle() }
        .accessibilityIdentifier("today.header.remaining")
    }

    @ViewBuilder
    private var bars: some View {
        MacroBar(label: "P", value: totals.proteinG, target: max(target.proteinG, 1), color: Design.Color.macroProtein)
        MacroBar(label: "C", value: totals.carbsG, target: max(target.carbsG, 1), color: Design.Color.macroCarbs)
        MacroBar(label: "F", value: totals.fatG, target: max(target.fatG, 1), color: Design.Color.macroFat)
    }

    // MARK: Ledger

    /// The day's meals (tap to fix, swipe to delete — no need to say so),
    /// then the way into the week's insights.
    private var ledger: some View {
        VStack(spacing: 0) {
            if !meals.isEmpty {
                HairlineRule().padding(.bottom, 4)
                if meals.count <= 5 || typeSize.isAccessibilitySize {
                    ledgerRows
                } else {
                    // A long day scrolls inside the header instead of pushing
                    // the thread off screen.
                    ScrollView { ledgerRows }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(height: 300)
                }
            }
            HairlineRule().padding(.top, 4)
            Button(action: onOpenInsights) {
                HStack {
                    Text("Week insights")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Design.Color.textSecondary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Design.Color.textTertiary)
                }
                .padding(.top, 12)
                .padding(.bottom, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Week insights")
            .accessibilityHint("Protein, weekly patterns and the protein guide")
        }
    }

    private var ledgerRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(meals.enumerated()), id: \.element.id) { index, meal in
                if index > 0 { HairlineRule() }
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
            HStack(spacing: 10) {
                Text(timeText(meal.createdAt).replacingOccurrences(of: " AM", with: "").replacingOccurrences(of: " PM", with: ""))
                    .font(Design.Typeface.numeral(.caption))
                    .monospacedDigit()
                    .foregroundStyle(Design.Color.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(minWidth: timeWidth, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    Text(meal.summary)
                        .font(.subheadline)
                        .foregroundStyle(meal.status == .complete ? Design.Color.textPrimary : Design.Color.textSecondary)
                        .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                    if meal.status == .complete {
                        MacroInline(p: meal.proteinG, c: meal.carbsG, f: meal.fatG)
                    } else if meal.status == .failed {
                        Text(meal.displayStatusMessage)
                            .font(.caption)
                            .foregroundStyle(Design.Color.danger)
                            .lineLimit(1)
                    } else {
                        ThreadShimmerLine(width: 72)
                            .accessibilityLabel("Working on it")
                    }
                }
                Spacer()
                if meal.status == .complete {
                    Text(Int(meal.caloriesKcal.rounded()).formatted())
                        .font(Design.Typeface.numeral(.subheadline, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(Design.Color.textPrimary)
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .matchedTransitionSource(id: TodayRoute.zoomID(meal.id, from: .ledger), in: zoomNamespace)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ledger.\(meal.id.uuidString)")
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
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: max(revealWidth, -offset))
                        .frame(maxHeight: .infinity)
                        .background(Design.Color.danger, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete meal")
            }
            content
                .background(Design.Color.surface1.opacity(offset < 0 ? 0.001 : 0))
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

struct WeekStrip: View {
    let days: [WeekStripDay]
    var onSelect: (String) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(days) { day in
                Button {
                    onSelect(day.localDay)
                } label: {
                    VStack(spacing: 5) {
                        Text(day.letter)
                            .font(Design.Typeface.eyebrow)
                            .foregroundStyle(day.isSelected ? Design.Color.ember : Design.Color.textTertiary)
                        MacroRings(kcal: day.kcalProgress, protein: day.proteinProgress, size: 30, lineWidth: 3.5)
                            .opacity(day.isFuture ? 0.3 : (day.hasLog || day.isSelected ? 1 : 0.55))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background {
                        if day.isSelected {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Design.Color.ember.opacity(0.12))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(day.isFuture)
                .accessibilityLabel(accessibilityLabel(day))
                .accessibilityAddTraits(day.isSelected ? .isSelected : [])
            }
        }
        .sensoryFeedback(.selection, trigger: days.first(where: \.isSelected)?.localDay)
    }

    private func accessibilityLabel(_ day: WeekStripDay) -> String {
        let name = ThreadCardCopy.weekdayName(day.localDay, short: false) ?? day.localDay
        if day.isFuture { return name }
        return "\(name), \(Int((day.kcalProgress * 100).rounded())) percent of calories"
    }
}
