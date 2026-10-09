import SwiftUI

// MARK: - Shared rhythm

/// Train's own spacing and type, built from the shared tokens.
enum TrainStyle {
    /// Horizontal page margin.
    static let gutter: CGFloat = Design.Space.gutter
    /// The hero panel's inner padding.
    static let heroPadding: CGFloat = 22
    /// Vertical rhythm between ledger rows.
    static let rowSpacing: CGFloat = 13

    /// A section's name: sentence case, small and quiet — the space above
    /// it does the separating, so it never needs a rule or a box.
    static func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Design.Color.textTertiary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A screen's large title in New York, for the navigation bar's large-title
/// slot (it still collapses to the plain inline title on scroll). Nudged
/// onto the page's 20 pt gutter so the title and the content share one edge.
struct TrainLargeTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Design.Typeface.display(.largeTitle))
            .foregroundStyle(Design.Color.textPrimary)
            .lineLimit(2)
            .padding(.leading, TrainStyle.gutter - 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Week: the plan in one line, the seven days as seals

/// The week at a glance: seven small seals (a lacquered disc with the
/// session's letter where Luke trained, a dot where he didn't, today ringed
/// in Pernambuco) and under them the plan's name with "3 of 4". No box —
/// it sits on the canvas like the date line of a journal page.
struct TrainWeekHeader: View {
    let planName: String?
    let week: TrainingWeekProgress
    var onOpenPlan: (() -> Void)?

    private static let weekdayNames = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 0) {
                ForEach(week.days) { day in
                    TrainDayPad(day: day)
                        .frame(maxWidth: .infinity)
                }
            }
            caption
        }
        .contentShape(Rectangle())
        .onTapGesture { onOpenPlan?() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(onOpenPlan == nil ? [] : .isButton)
        .accessibilityHint(onOpenPlan == nil ? "" : "Opens your training plan")
    }

    private var caption: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(planName ?? "This week")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Design.Color.textSecondary)
                .lineLimit(1)
            if let count = week.countLabel {
                Text("·")
                    .font(.footnote)
                    .foregroundStyle(Design.Color.textTertiary)
                Text(count)
                    .font(Design.Typeface.numeral(.footnote, weight: .medium))
                    .foregroundStyle(Design.Color.textSecondary)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(week.completed)))
            }
            if onOpenPlan != nil {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Design.Color.textTertiary)
            }
        }
    }

    private var accessibilityText: String {
        let count = week.target.map { "\(week.completed) of \($0) sessions this week" }
            ?? "\(week.completed) session\(week.completed == 1 ? "" : "s") this week"
        let days = week.days.indices.filter { week.days[$0].trained }.map { Self.weekdayNames[$0 % 7] }
        let trained = days.isEmpty ? "" : ": " + days.formatted(.list(type: .and))
        return [planName, count + trained].compactMap { $0 }.joined(separator: ", ")
    }
}

/// One day of the week strip. Trained days are lacquered heartwood seals
/// (the same lacquer as Luke's own chat bubbles — things he did); a walk or
/// a ride is just its glyph; rest days are a single dot. Today's letter and
/// ring are the strip's only Pernambuco. A seal settles in with a small
/// press when a session lands.
struct TrainDayPad: View {
    let day: TrainingWeekDay

    @ScaledMetric(relativeTo: .body) private var sealSize: CGFloat = 34
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var size: CGFloat { min(sealSize, 46) }

    var body: some View {
        VStack(spacing: 9) {
            Text(day.weekdayInitial)
                .font(.caption2.weight(day.isToday ? .bold : .medium))
                .foregroundStyle(day.isToday ? Design.Color.pernambuco : Design.Color.textTertiary)
            ZStack {
                if day.trained {
                    Circle()
                        .fill(Design.Color.bubbleMe)
                        .transition(reduceMotion ? .opacity : .scale(scale: 1.25).combined(with: .opacity))
                }
                mark
                if day.isToday {
                    Circle()
                        .strokeBorder(Design.Color.pernambuco.opacity(day.trained ? 0.9 : 0.75), lineWidth: 1.25)
                        .padding(day.trained ? -3.5 : 0)
                }
            }
            .frame(width: size, height: size)
            .animation(Design.Motion.gated(Design.Motion.arrive, reduceMotion: reduceMotion), value: day.trained)
        }
    }

    @ViewBuilder
    private var mark: some View {
        if day.trained, let marker = day.marker {
            Text(marker)
                .font(Design.Typeface.numeral(.footnote, weight: .semibold))
                .foregroundStyle(Design.Color.onBubbleMe)
        } else if let symbol = day.symbolName {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(day.trained ? Design.Color.onBubbleMe : Design.Color.textTertiary)
        } else {
            Circle()
                .fill(day.isFuture ? Design.Color.surface3 : Design.Color.textDisabled)
                .frame(width: 4, height: 4)
        }
    }
}

// MARK: - The hero: today's session

/// The hero's heading: a small Pernambuco line ("Next up · ~55 min"), then
/// the session's name in New York.
struct TrainHeroHeading: View {
    let label: String
    var detail: String?
    let title: String
    var prCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Design.Color.pernambuco)
                if let detail {
                    Text("·")
                        .font(.footnote)
                        .foregroundStyle(Design.Color.textTertiary)
                    Text(detail)
                        .font(Design.Typeface.numeral(.footnote, weight: .medium))
                        .foregroundStyle(Design.Color.textTertiary)
                        .monospacedDigit()
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                    .font(Design.Typeface.display(.largeTitle))
                    .foregroundStyle(Design.Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if prCount > 0 {
                    TrainPRBadge(count: prCount)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The plan's next session: every lift with today's number (Pernambuco
/// where the weight goes up), "Log session" (voice, through the capture
/// bar) and a quiet way to type it or add a screenshot instead. The one
/// panel on the Train tab — everything else sits on the canvas.
struct NextSessionCard: View {
    let session: TrainingSession
    let targets: [LiftTarget]
    let onLog: () -> Void
    let onType: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            TrainHeroHeading(
                label: "Next up",
                detail: session.estMinutes.map { "~\($0) min" },
                title: session.name)
            VStack(spacing: TrainStyle.rowSpacing) {
                ForEach(targets) { target in
                    LiftTargetRow(target: target)
                }
            }
            HStack(spacing: 10) {
                Button(action: onLog) {
                    Label("Log session", systemImage: "mic.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                Button(action: onType) {
                    Image(systemName: "keyboard")
                        .frame(minWidth: 22)
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityLabel("Type it or add a screenshot")
            }
            .padding(.top, 2)
        }
        .padding(TrainStyle.heroPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(radius: Design.Radius.cardLarge)
    }
}

/// A lift on the left, its numbers on the right — stacked when Dynamic Type
/// leaves no room for both on one line.
struct TrainValueRow<Trailing: View>: View {
    let name: String
    let trailing: Trailing

    init(_ name: String, @ViewBuilder trailing: () -> Trailing) {
        self.name = name
        self.trailing = trailing()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                label.lineLimit(1)
                Spacer(minLength: 12)
                trailing.fixedSize()
            }
            VStack(alignment: .leading, spacing: 2) {
                label
                trailing
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var label: some View {
        Text(name)
            .font(.subheadline)
            .foregroundStyle(Design.Color.textSecondary)
    }
}

extension TrainValueRow where Trailing == Text {
    /// The common case: numbers as one tabular string.
    init(_ name: String, value: String, color: Color = Design.Color.textPrimary) {
        self.init(name) {
            Text(value)
                .font(Design.Typeface.numeral(.subheadline, weight: .medium))
                .foregroundStyle(color)
                .monospacedDigit()
        }
    }
}

struct LiftTargetRow: View {
    let target: LiftTarget

    var body: some View {
        TrainValueRow(
            ActivitySummaryFormatter.shortLiftName(target.exercise.name),
            value: target.prescription,
            color: target.addsWeight ? Design.Color.pernambuco : Design.Color.textPrimary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let name = ActivitySummaryFormatter.shortLiftName(target.exercise.name)
        guard target.addsWeight, let delta = target.deltaLabel else { return "\(name), \(target.prescription)" }
        return "\(name), \(target.prescription), up \(delta.dropFirst())"
    }
}

// MARK: - Logged today

/// Today's plan session once it's logged: the lifts as done (Pernambuco
/// where a PR landed). While it's read, the words as said, shimmering.
struct LoggedSessionCard: View {
    let activity: Activity
    var sessionName: String?
    var units: String = "imperial"

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var durationText: String? {
        guard !activity.isProcessing, let minutes = activity.durationMin, minutes > 0 else { return nil }
        return ActivitySummaryFormatter.durationText(minutes: minutes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            TrainHeroHeading(
                label: "Today",
                detail: durationText,
                title: sessionName ?? activity.title,
                prCount: activity.isProcessing ? 0 : activity.prs.count)
            Group {
                if activity.isProcessing {
                    Text(ActivityCard.readingLine(for: activity))
                        .font(.subheadline)
                        .foregroundStyle(Design.Color.textSecondary)
                        .lineSpacing(3)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .shimmering()
                        .transition(.opacity)
                } else {
                    lifts
                        .transition(.ink(reduceMotion: reduceMotion))
                }
            }
        }
        .padding(TrainStyle.heroPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(radius: Design.Radius.cardLarge)
        .animation(Design.Motion.calm(Design.Motion.arrive, reduceMotion: reduceMotion), value: activity.isProcessing)
    }

    private var lifts: some View {
        let prNames = Set(activity.prs.map { LiftIdentity.normalizedName($0.exercise) })
        return VStack(spacing: TrainStyle.rowSpacing) {
            ForEach(Array(activity.exercises.filter { !$0.workingSets.isEmpty }.enumerated()), id: \.offset) { _, exercise in
                let isPR = prNames.contains(LiftIdentity.normalizedName(exercise.name))
                TrainValueRow(
                    ActivitySummaryFormatter.shortLiftName(exercise.name),
                    value: ActivitySummaryFormatter.exerciseSummary(exercise, units: units),
                    color: isPR ? Design.Color.pernambuco : Design.Color.textPrimary)
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(isPR ? "Personal record" : "")
            }
        }
    }
}

// MARK: - Plan states

/// No plan yet: the hero slot asks Shudo for one.
struct EmptyPlanCard: View {
    let onBuild: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("No plan yet")
                    .font(Design.Typeface.display(.largeTitle))
                    .foregroundStyle(Design.Color.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text("Shudo will build one around your week.")
                    .font(.subheadline)
                    .foregroundStyle(Design.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: onBuild) {
                Text("Build my plan")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(TrainStyle.heroPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(radius: Design.Radius.cardLarge)
    }
}

/// A plan Shudo drafted: what changed, run it or change it. Tapping the
/// words opens the full plan.
struct DraftPlanCard: View {
    let plan: TrainingPlan
    var isActivating: Bool
    let onRun: () -> Void
    let onChange: () -> Void
    let onDetails: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button(action: onDetails) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("A new plan from Shudo")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Design.Color.oak)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(plan.plan.name)
                            .font(Design.Typeface.display(.title2))
                            .foregroundStyle(Design.Color.textPrimary)
                            .multilineTextAlignment(.leading)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Design.Color.textTertiary)
                    }
                    if let summary = plan.changeSummary ?? plan.rationale {
                        Text(summary)
                            .font(.subheadline)
                            .foregroundStyle(Design.Color.textSecondary)
                            .lineSpacing(2)
                            .lineLimit(4)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows the whole plan")
            HStack(spacing: 10) {
                Button(action: onRun) {
                    HStack(spacing: 6) {
                        if isActivating { ProgressView().tint(Design.Color.onCream) }
                        Text("Run it")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isActivating)
                Button(action: onChange) {
                    Text("Change it").frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(TrainStyle.heroPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(radius: Design.Radius.cardLarge)
    }
}

// MARK: - Records

/// The PR board as a ledger: one line per lift — name, the set that earned
/// it, the estimated max. Numbers stay hinoki; only a record set this week
/// takes the accent.
struct PRBoardCard: View {
    let bests: [PersonalBest]
    var units: String = "imperial"
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    static let collapsedCount = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                TrainStyle.sectionLabel("Records")
                Spacer()
                Text("est. 1RM")
                    .font(.caption)
                    .foregroundStyle(Design.Color.textTertiary)
                    .accessibilityLabel("Estimated one-rep max")
            }
            .padding(.bottom, 6)
            ForEach(Array(bests.enumerated()), id: \.element.id) { index, best in
                if expanded || index < Self.collapsedCount {
                    PRBoardRow(best: best, units: units)
                        .padding(.vertical, 9)
                        .transition(.ink(reduceMotion: reduceMotion))
                }
            }
            if bests.count > Self.collapsedCount {
                Button {
                    withAnimation(Design.Motion.calm(Design.Motion.settle, reduceMotion: reduceMotion)) {
                        expanded.toggle()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(expanded ? "Fewer" : "All \(bests.count) lifts")
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Design.Color.textTertiary)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
    }
}

/// One lift: name and the set that earned it on the left, the estimated
/// max on the right — Pernambuco when it moved this week.
struct PRBoardRow: View {
    let best: PersonalBest
    var units: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                name
                setText
                Spacer(minLength: 12)
                value
            }
            VStack(alignment: .leading, spacing: 3) {
                name
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    setText
                    Spacer(minLength: 8)
                    value
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(best.isFresh ? "New this week" : "")
    }

    private var name: some View {
        Text(ActivitySummaryFormatter.shortLiftName(best.name))
            .font(.subheadline)
            .foregroundStyle(Design.Color.textPrimary)
            .lineLimit(1)
    }

    private var setText: some View {
        Text(ActivitySummaryFormatter.setText(best.bestSet, units: units))
            .font(Design.Typeface.numeral(.caption, weight: .regular))
            .foregroundStyle(Design.Color.textTertiary)
            .monospacedDigit()
            .lineLimit(1)
    }

    private var value: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            if let pounds = best.e1rmPounds {
                let unit = WeightUnit(preference: units)
                Text(Int(StrengthMath.convert(pounds: pounds, to: unit).rounded()).formatted())
                    .font(Design.Typeface.numeral(.body, weight: .medium))
                    .foregroundStyle(best.isFresh ? Design.Color.pernambuco : Design.Color.textPrimary)
                    .monospacedDigit()
                Text(unit.rawValue)
                    .font(.caption)
                    .foregroundStyle(Design.Color.textTertiary)
            } else {
                Text("\(best.bestSet.reps)")
                    .font(Design.Typeface.numeral(.body, weight: .medium))
                    .foregroundStyle(best.isFresh ? Design.Color.pernambuco : Design.Color.textPrimary)
                    .monospacedDigit()
                Text("reps")
                    .font(.caption)
                    .foregroundStyle(Design.Color.textTertiary)
            }
        }
        .fixedSize()
    }
}

// MARK: - Recent

/// One past workout as a quiet line in the history: kind glyph and name,
/// the one stat line beneath. The day sits in a narrow column on the left,
/// written once per day like a training diary.
struct ActivityLedgerRow: View {
    let activity: Activity
    var units: String = "imperial"
    /// "Today", "Thu", "Oct 2" — only on a day's first row.
    var dayLabel: String?
    var dayColumnWidth: CGFloat?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            if let dayColumnWidth {
                Text(dayLabel ?? " ")
                    .font(.footnote)
                    .foregroundStyle(Design.Color.textTertiary)
                    .lineLimit(1)
                    .frame(width: dayColumnWidth, alignment: .leading)
                    .accessibilityHidden(dayLabel == nil)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: activity.kind.symbolName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Design.Color.textTertiary)
                        .symbolEffect(.pulse, options: .repeating, isActive: activity.isProcessing)
                        .accessibilityHidden(true)
                    Text(activity.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Design.Color.textPrimary)
                        .lineLimit(1)
                    if !activity.isProcessing, !activity.prs.isEmpty {
                        Text(activity.prs.count > 1 ? "\(activity.prs.count) PRs" : "PR")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Design.Color.pernambuco)
                            .accessibilityLabel(activity.prs.count > 1
                                ? "\(activity.prs.count) personal records" : "Personal record")
                    }
                }
                statusLine
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var statusLine: some View {
        if activity.isProcessing {
            Text(ActivityCard.readingLine(for: activity))
                .font(.footnote)
                .foregroundStyle(Design.Color.textSecondary)
                .lineLimit(1)
                .shimmering()
        } else if activity.status == .failed {
            Text("Couldn’t read this one")
                .font(.footnote)
                .foregroundStyle(Design.Color.danger)
        } else if let line = ActivitySummaryFormatter.statLine(for: activity, units: units) {
            Text(line)
                .font(Design.Typeface.numeral(.footnote, weight: .regular))
                .foregroundStyle(Design.Color.textSecondary)
                .lineLimit(2)
        }
    }

    /// The diary column: "Today", a weekday within the last six days,
    /// otherwise "Oct 2".
    static func dayLabel(localDay: String, today: String, timezone: String) -> String {
        if localDay == today { return "Today" }
        guard let date = TrainCalendar.date(fromLocalDay: localDay, timezone: timezone),
              let todayDate = TrainCalendar.date(fromLocalDay: today, timezone: timezone) else {
            return TrainSnapshot.displayTitle(localDay: localDay)
        }
        var style = Date.FormatStyle.dateTime
        style.timeZone = TimeZone(identifier: timezone) ?? .current
        let days = todayDate.timeIntervalSince(date) / 86_400
        return days < 6.5
            ? date.formatted(style.weekday(.abbreviated))
            : date.formatted(style.month(.abbreviated).day())
    }
}

// MARK: - Plan detail sheet

/// The whole plan, as a page: the name in New York, then each session as a
/// short list separated by space, not boxes.
struct TrainingPlanSheet: View {
    let plan: TrainingPlan
    var isActivating = false
    var onRun: (() -> Void)?
    var onChange: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Space.section) {
                    VStack(alignment: .leading, spacing: 8) {
                        if plan.status == .draft {
                            Text("Draft")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Design.Color.oak)
                        }
                        Text(plan.plan.name)
                            .font(Design.Typeface.display(.largeTitle))
                            .foregroundStyle(Design.Color.textPrimary)
                            .accessibilityAddTraits(.isHeader)
                        Text("\(plan.plan.sessionsPerWeek) days a week")
                            .font(.subheadline)
                            .foregroundStyle(Design.Color.textSecondary)
                        if let notes = plan.rationale ?? plan.plan.notes {
                            Text(notes)
                                .font(.subheadline)
                                .foregroundStyle(Design.Color.textTertiary)
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 6)
                        }
                    }
                    ForEach(plan.plan.orderedSessions) { session in
                        sessionSection(session)
                    }
                    if let conditioning = plan.plan.conditioning {
                        Label(conditioning.summary, systemImage: "figure.outdoor.cycle")
                            .font(.subheadline)
                            .foregroundStyle(Design.Color.textSecondary)
                    }
                    VStack(spacing: 10) {
                        if let onRun, plan.status == .draft {
                            Button {
                                onRun()
                            } label: {
                                Text(isActivating ? "Starting…" : "Run it").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(isActivating)
                        }
                        Button {
                            dismiss()
                            onChange()
                        } label: {
                            Text("Change it").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                }
                .padding(.horizontal, TrainStyle.gutter)
                .padding(.top, 8)
                .padding(.bottom, Design.Space.xxl)
            }
            .background(AppBackground())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(Design.Radius.sheet)
    }

    private func sessionSection(_ session: TrainingSession) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(session.name)
                    .font(Design.Typeface.display(.title3))
                    .foregroundStyle(Design.Color.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                if let focus = session.focus {
                    Text(focus)
                        .font(.footnote)
                        .foregroundStyle(Design.Color.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let minutes = session.estMinutes {
                    Text("~\(minutes) min")
                        .font(Design.Typeface.numeral(.caption, weight: .medium))
                        .foregroundStyle(Design.Color.textTertiary)
                        .monospacedDigit()
                }
            }
            VStack(alignment: .leading, spacing: TrainStyle.rowSpacing) {
                ForEach(Array(session.exercises.enumerated()), id: \.offset) { _, exercise in
                    VStack(alignment: .leading, spacing: 3) {
                        TrainValueRow(exercise.name, value: exercise.prescription)
                        let meta = [exercise.restSec.map { "Rest \(Self.restText($0))" }, exercise.cue].compactMap { $0 }
                        if !meta.isEmpty {
                            Text(meta.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(Design.Color.textTertiary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    static func restText(_ seconds: Int) -> String {
        seconds >= 60 && seconds % 60 == 0 ? "\(seconds / 60) min"
            : seconds > 60 ? "\(seconds / 60):\(String(format: "%02d", seconds % 60))" : "\(seconds)s"
    }
}
