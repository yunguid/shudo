import SwiftUI
import UIKit

/// The top of the day, written like a diary page: the day's name in serif
/// (tap it for the calendar), where Luke is in the phase, and one figure —
/// kcal left — over two brushstrokes, calories and protein. Nothing boxed.
///
/// Tap the figure, or pull it down, and the day unfolds beneath it: a sheet
/// of the same paper drawn down from under the strokes, with the macros,
/// the meals (tap to open, swipe to delete with undo) and the week. The
/// sheet follows the finger and gives a little past either end; let go and
/// it settles on the house spring, carrying the finger's speed. The header
/// itself never moves and the thread never reflows — the sheet lies over
/// it, and a push up, a tap on the thread or a pull on it folds the day
/// away again.
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
    /// The profile's timezone, for the meals' clock times.
    let timeZone: TimeZone
    var onSelectDay: (String) -> Void
    var onOpenMeal: (Entry) -> Void
    var onDeleteMeal: (Entry) -> Void
    var onOpenInsights: () -> Void
    let zoomNamespace: Namespace.ID
    /// A finished day in the diary: what's left reads as "short".
    var isPast = false
    /// The day the figure's numbers belong to; a new one hands the whole
    /// figure line off at once.
    var figureDay = ""
    /// The selected day's numbers are still on their way: the old day's
    /// figure (and its meals) wait, dimmed.
    var isSettling = false
    @ViewBuilder var account: Account
    @ViewBuilder var dayPicker: DayPicker

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.shellBandInset) private var bandInset

    /// The open fraction while a finger holds the sheet — unclamped, since
    /// past either end it resists — or nil when nothing holds it.
    @State private var held: CGFloat?
    @State private var holdAxis = HoldAxis.undecided
    /// Where the sheet was when the hold took over, and the finger's travel
    /// before it did (so the sheet never jumps to catch up).
    @State private var holdBase: CGFloat = 0
    @State private var holdSlack: CGFloat = 0
    /// Resets even when the system cancels a drag, so the sheet always
    /// settles.
    @GestureState private var isHolding = false
    /// Measured: the sheet and its parts, the header's bottom and the
    /// bottom of the window, which bound the room the sheet may use.
    @State private var sheetHeight: CGFloat = 0
    @State private var sectionsHeight: CGFloat = 0
    @State private var macrosHeight: CGFloat = 0
    @State private var weekHeight: CGFloat = 0
    @State private var ledgerContentHeight: CGFloat = 0
    @State private var headerBottom: CGFloat = 0
    @State private var windowFloor: CGFloat = 0
    /// The last settled day's meals, shown (dimmed, with its figure) while
    /// a new day's meals are on their way.
    @State private var settledMeals: [Entry] = []

    /// How far the canvas behind the header dissolves into the thread.
    private let fade: CGFloat = 26

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleRow
            figure
        }
        .padding(.horizontal, Design.Space.gutter)
        .padding(.top, Design.Space.xs)
        .padding(.bottom, Design.Space.s)
        .background(alignment: .top) { backdrop }
        .contentShape(Rectangle())
        // A pull anywhere on the header — the name, the figure, the corner.
        .simultaneousGesture(hold(from: .header))
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { bottom in
            headerBottom = bottom
            windowFloor = Self.measuredWindowFloor
        }
        // The open day hangs from the header's bottom edge, over the thread.
        .overlay(alignment: .bottom) {
            unfolded
                .alignmentGuide(.bottom) { $0[.top] }
        }
        .onChange(of: isHolding) { _, holding in
            guard !holding else { return }
            holdAxis = .undecided
            // A drag the system cancelled never reaches onEnded.
            if held != nil { setExpanded(progress > 0.5) }
        }
        .onChange(of: meals, initial: true) { _, meals in
            if !isSettling { settledMeals = meals }
        }
        .onChange(of: isSettling) { _, settling in
            if !settling { settledMeals = meals }
        }
        #if DEBUG
        .task { await DayPanelPreview.playMotion { setExpanded($0) } }
        #endif
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
                        // "typing…" takes over from "Day 35 of the bulk" the
                        // same way: a hand-off, never two lines blended.
                        ZStack(alignment: .leading) {
                            Text(subtitle)
                                .font(Design.Typeface.text(.caption))
                                .foregroundStyle(subtitleIsLive ? Design.Color.ember : Design.Color.textTertiary)
                                .lineLimit(1)
                                .id(subtitle)
                                .transition(.inkHandoff(reduceMotion: reduceMotion))
                        }
                    }
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isPickingDay, arrowEdge: .top) { dayPicker }
            .animation(Design.Motion.calm(Design.Motion.breath, reduceMotion: reduceMotion), value: subtitle)
            // "Today, Day 35 of the bulk" / "Today, typing…" in one label.
            .accessibilityLabel(subtitle.map { "\(title), \($0)" } ?? title)
            .accessibilityHint("Pick a day")
            .accessibilityIdentifier("today.day")

            Spacer(minLength: 0)
            account
        }
        .frame(minHeight: 44)
    }

    // MARK: The figure

    /// Number, label, macros and strokes are one line of the diary: when
    /// the day they describe changes they hand off together (old gone
    /// quickly, new inks in), overlapping in place. Opening the day never
    /// touches them — the figure is the same open or shut. To VoiceOver
    /// the whole line is the one button that opens and folds the day.
    private var figure: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                figureRow
                    .padding(.top, Design.Space.l)
                meter
                    .padding(.top, Design.Space.m)
            }
            .id(figureDay)
            .transition(.inkHandoff(reduceMotion: reduceMotion))
        }
        .opacity(isSettling ? 0.4 : 1)
        .animation(Design.Motion.calm(Design.Motion.settle, reduceMotion: reduceMotion), value: figureDay)
        .animation(Design.Motion.calm(Design.Motion.breath, reduceMotion: reduceMotion), value: isSettling)
        .contentShape(Rectangle())
        .onTapGesture { toggle() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(expanded ? "expanded" : "collapsed")
        .accessibilityHint(expanded ? "Folds the day away" : "Shows your macros, meals and the week")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { toggle() }
        .accessibilityIdentifier("today.header.remaining")
    }

    /// "855 kcal left" with the macros at the trailing edge (under it at
    /// accessibility sizes).
    private var figureRow: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Design.Space.s))
            : AnyLayout(HStackLayout(alignment: .lastTextBaseline, spacing: Design.Space.m))
        return layout {
            remaining
            if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
            macroSummary
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

    /// Two brushstrokes: calories in hinoki, protein in Pernambuco.
    private var meter: some View {
        VStack(spacing: 5) {
            DayStroke(progress: numbers.kcalProgress, color: Design.Color.macroKcal)
            DayStroke(progress: numbers.proteinProgress, color: Design.Color.macroProtein)
        }
        .animation(Design.Motion.gated(Design.Motion.ring, reduceMotion: reduceMotion), value: numbers)
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

    // MARK: The open day

    /// 0 shut, 1 open; a held sheet past either end gives a little.
    private var progress: CGFloat {
        if let held { return DayPanelMotion.rubberBand(held) }
        return expanded ? 1 : 0
    }

    /// The thread veiled under the open day, and the sheet over it.
    private var unfolded: some View {
        let progress = self.progress
        return ZStack(alignment: .top) {
            // Shut, the 2,000-point veil would sit over the whole thread.
            if progress > 0 { veil(progress) }
            DayPanelSheet(progress: progress, top: headerBottom, reduceMotion: reduceMotion) {
                sheet(progress)
            }
            .clipShape(BelowTopEdge())
        }
    }

    /// The thread, dimmed while the day is open: the page is in front now.
    /// A tap on it, or a pull on it, hands the page back to the thread.
    private func veil(_ progress: CGFloat) -> some View {
        Design.Color.canvas
            .opacity(0.5 * Double(min(max(progress, 0), 1)))
            // Past the bottom of any phone; the band and the pills sit above it.
            .frame(height: 2_000)
            .contentShape(Rectangle())
            .onTapGesture { setExpanded(false) }
            .simultaneousGesture(hold(from: .thread))
            .allowsHitTesting(expanded)
            .accessibilityHidden(true)
    }

    /// Macros, meals, the week — inking in in that order as the sheet
    /// unfolds. Every part pulls the sheet except a meal list that scrolls.
    private func sheet(_ progress: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if typeSize.isAccessibilitySize {
                // Large text: the whole day scrolls inside the room it has,
                // and only the grabber below it pulls.
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        macros(progress)
                        meals(progress)
                        week(progress)
                    }
                    .padding(.bottom, 18)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { sectionsHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(sectionsHeight, max(room - 40, 240)))
                .runsOnBelow()
                grabber(progress)
            } else {
                // The list gets what the rest leaves; measuring the rest (never
                // the list) keeps the measurement from chasing itself.
                macros(progress)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { macrosHeight = $0 }
                meals(progress)
                VStack(alignment: .leading, spacing: 0) {
                    week(progress)
                    grabber(progress)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { weekHeight = $0 }
            }
        }
        .animation(Design.Motion.calm(Design.Motion.breath, reduceMotion: reduceMotion), value: isSettling)
        .padding(.horizontal, Design.Space.gutter)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { sheetHeight = $0 }
        .allowsHitTesting(expanded)
        // VoiceOver's scrub folds the day, as the escape gesture should.
        .accessibilityAction(.escape) { setExpanded(false) }
        // Folded, the sheet is one empty, hidden element: VoiceOver never
        // wanders into a day that isn't open.
        .accessibilityElement(children: expanded ? .contain : .ignore)
        .accessibilityHidden(!expanded)
    }

    private var sheetPulls: Bool { !typeSize.isAccessibilitySize }

    private func macros(_ progress: CGFloat) -> some View {
        DayMacroTrio(totals: totals, target: target)
            .opacity(isSettling ? 0.4 : 1)
            .padding(.top, Design.Space.l)
            .modifier(PanelInk(progress: progress, start: 0.1, reduceMotion: reduceMotion))
            .simultaneousGesture(hold(from: .sheet), including: sheetPulls ? .all : .subviews)
    }

    private func meals(_ progress: CGFloat) -> some View {
        ledger
            .opacity(isSettling ? 0.4 : 1)
            .padding(.top, Self.ledgerGap)
            .modifier(PanelInk(progress: progress, start: 0.25, reduceMotion: reduceMotion))
            .simultaneousGesture(hold(from: .sheet), including: sheetPulls && !ledgerScrolls ? .all : .subviews)
    }

    private func week(_ progress: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            WeekStrip(days: weekDays, onSelect: onSelectDay)
                .padding(.top, Design.Space.xl)
                .modifier(PanelInk(progress: progress, start: 0.42, reduceMotion: reduceMotion))
            insightsLink
                .padding(.top, Design.Space.xs)
                .modifier(PanelInk(progress: progress, start: 0.5, reduceMotion: reduceMotion))
        }
        .simultaneousGesture(hold(from: .sheet), including: sheetPulls ? .all : .subviews)
    }

    /// The sheet's end: a small grain to push it back up by.
    private func grabber(_ progress: CGFloat) -> some View {
        Capsule()
            .fill(Design.Color.textTertiary.opacity(0.4))
            .frame(width: 36, height: 4)
            .frame(maxWidth: .infinity)
            .padding(.top, Design.Space.s)
            .padding(.bottom, Design.Space.m)
            .contentShape(Rectangle())
            .onTapGesture { setExpanded(false) }
            .simultaneousGesture(hold(from: .sheet))
            .modifier(PanelInk(progress: progress, start: 0.55, reduceMotion: reduceMotion))
            .accessibilityHidden(true)
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

    /// The room under the header the sheet may fill: down to the command
    /// band, with a little air above it.
    private var room: CGFloat {
        guard windowFloor > 0, headerBottom > 0 else { return .infinity }
        return windowFloor - bandInset - headerBottom - Design.Space.m
    }

    /// The bottom of the window above the home indicator. UIKit knows it;
    /// the header's own geometry stops at the header.
    private static var measuredWindowFloor: CGFloat {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first else { return 0 }
        return window.bounds.height - window.safeAreaInsets.bottom
    }

    // MARK: Meals

    private var ledgerMeals: [Entry] { isSettling ? settledMeals : meals }

    /// A long day scrolls inside the sheet instead of pushing past the band.
    private var ledgerCap: CGFloat {
        max(Self.ledgerFloor, room - macrosHeight - Self.ledgerGap - weekHeight)
    }

    private var ledgerScrolls: Bool {
        !typeSize.isAccessibilitySize && ledgerContentHeight > ledgerCap + 1
    }

    /// Two and a half meals: always enough to see that the list goes on.
    private static var ledgerFloor: CGFloat { 132 }
    private static var ledgerGap: CGFloat { Design.Space.xl }

    /// The day's meals, one to a line pair (tap to open, swipe to delete —
    /// no need to say so). Rows are separated by space, not rules.
    private var ledger: some View {
        let meals = ledgerMeals
        return Group {
            if meals.isEmpty {
                Text(isPast ? "Nothing logged" : "Nothing logged yet")
                    .font(Design.Typeface.text(.subheadline))
                    .foregroundStyle(Design.Color.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            } else if ledgerScrolls {
                ScrollView {
                    ledgerRows(meals)
                        .padding(.bottom, 18)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.hidden)
                .frame(height: ledgerCap)
                .runsOnBelow()
            } else {
                ledgerRows(meals)
            }
        }
    }

    private func ledgerRows(_ meals: [Entry]) -> some View {
        let keepsPhotoMargin = meals.contains { $0.imageURL != nil }
        return VStack(spacing: 0) {
            ForEach(meals) { meal in
                LedgerSwipeRow(onDelete: { onDeleteMeal(meal) }, canDelete: meal.canDelete) {
                    ledgerRow(meal, keepsPhotoMargin: keepsPhotoMargin)
                }
                // A deleted meal (or another day's list) is gone before
                // the rows close up; a new one inks in once there's room.
                .transition(.inkHandoff(reduceMotion: reduceMotion))
            }
        }
        .animation(Design.Motion.calm(Design.Motion.settle, reduceMotion: reduceMotion), value: meals.map(\.id))
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { ledgerContentHeight = $0 }
    }

    /// A finished meal opens its page — the same page its receipt in the
    /// thread opens, zooming from this row. One still being read has
    /// nothing to open yet.
    @ViewBuilder
    private func ledgerRow(_ meal: Entry, keepsPhotoMargin: Bool) -> some View {
        let row = DayMealRow(
            meal: meal,
            time: Design.Clock.short(meal.createdAt, timeZone: timeZone),
            keepsPhotoMargin: keepsPhotoMargin
        )
        if meal.status == .complete {
            Button {
                onOpenMeal(meal)
            } label: {
                row
            }
            .buttonStyle(.plain)
            .matchedTransitionSource(id: TodayRoute.zoomID(meal.id, from: .ledger), in: zoomNamespace)
            .accessibilityHint("Opens the meal")
            .accessibilityIdentifier("ledger.\(meal.id.uuidString)")
        } else {
            row
                .accessibilityIdentifier("ledger.\(meal.id.uuidString)")
        }
    }

    // MARK: Holding the sheet

    private enum HoldAxis { case undecided, vertical, ignored }

    /// Where a pull began: the header, the open sheet, or the veiled thread.
    private enum HoldOrigin { case header, sheet, thread }

    private func hold(from origin: HoldOrigin) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .updating($isHolding) { _, holding, _ in holding = true }
            .onChanged { value in holdMoved(value, from: origin) }
            .onEnded { value in holdReleased(value) }
    }

    /// The sheet's edge follows the finger one to one.
    private func holdMoved(_ value: DragGesture.Value, from origin: HoldOrigin) {
        let rise = value.translation.height
        if holdAxis == .undecided {
            // Sideways belongs to a row's swipe or the day's edge swipe; a
            // pull down on the thread means Luke wants the thread back.
            let isVertical = abs(rise) > abs(value.translation.width) * 1.2
            guard isVertical, !(origin == .thread && rise > 0) else {
                holdAxis = .ignored
                if origin == .thread { setExpanded(false) }
                return
            }
            holdAxis = .vertical
            holdBase = expanded ? 1 : 0
            holdSlack = rise
        }
        guard holdAxis == .vertical else { return }
        held = holdBase + (rise - holdSlack) / pullHeight
    }

    /// What a pull is measured against: the sheet's height. Shut, the sheet
    /// isn't laid out, so until it has opened once a pull uses the room it
    /// will open into.
    private var pullHeight: CGFloat {
        sheetHeight > 0 ? sheetHeight : min(max(room, 240), 480)
    }

    /// Let go: a flick goes where it was flung, a slow release to the
    /// nearer end, carrying the finger's speed.
    private func holdReleased(_ value: DragGesture.Value) {
        let axis = holdAxis
        holdAxis = .undecided
        guard axis == .vertical, held != nil else { return }
        let velocity = value.velocity.height / pullHeight
        setExpanded(DayPanelMotion.opens(at: progress, velocity: velocity), velocity: velocity)
    }

    private func toggle() {
        setExpanded(!expanded)
    }

    /// Opens or folds the day on the house's bounce-free springs — the fold
    /// quicker than the unfolding — from wherever the sheet is.
    private func setExpanded(_ open: Bool, velocity: CGFloat = 0) {
        let spring = open ? DayPanelMotion.open : DayPanelMotion.close
        let speed = DayPanelMotion.initialVelocity(velocity, from: progress, to: open ? 1 : 0, spring: spring)
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .interpolatingSpring(spring, initialVelocity: speed)) {
            held = nil
            expanded = open
        }
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
