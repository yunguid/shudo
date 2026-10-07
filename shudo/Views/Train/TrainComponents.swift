import SwiftUI

// MARK: - Week strip: plan name, "2 of 4", the seven days

struct TrainWeekHeader: View {
    let planName: String?
    let week: TrainingWeekProgress
    var onOpenPlan: (() -> Void)?

    private static let weekdayNames = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(planName ?? "This week").eyebrowStyle()
                    .lineLimit(1)
                if onOpenPlan != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(Design.Color.textTertiary)
                }
                Spacer(minLength: 8)
                if let count = week.countLabel {
                    Text(count)
                        .font(Design.Typeface.numeral(.footnote, weight: .semibold))
                        .foregroundStyle(Design.Color.textSecondary)
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(week.completed)))
                }
            }
            HStack(spacing: 6) {
                ForEach(week.days) { day in
                    TrainDayPad(day: day)
                }
            }
        }
        .padding(16)
        .cardSurface()
        .contentShape(Rectangle())
        .onTapGesture { onOpenPlan?() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(onOpenPlan == nil ? [] : .isButton)
        .accessibilityHint(onOpenPlan == nil ? "" : "Opens your training plan")
    }

    private var accessibilityText: String {
        let count = week.target.map { "\(week.completed) of \($0) sessions this week" }
            ?? "\(week.completed) session\(week.completed == 1 ? "" : "s") this week"
        let days = week.days.indices.filter { week.days[$0].trained }.map { Self.weekdayNames[$0 % 7] }
        let trained = days.isEmpty ? "" : ": " + days.formatted(.list(type: .and))
        return [planName, count + trained].compactMap { $0 }.joined(separator: ", ")
    }
}

struct TrainDayPad: View {
    let day: TrainingWeekDay

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(day.trained ? AnyShapeStyle(Design.Color.emberFill) : AnyShapeStyle(Design.Color.surface2))
                    .shadow(color: day.trained ? Design.Color.ember.opacity(0.35) : .clear, radius: 5)
                content
            }
            .frame(maxWidth: .infinity, minHeight: 40)
            .overlay {
                if day.isToday, !day.trained {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Design.Color.ember, lineWidth: 1.5)
                }
            }
            .opacity(day.isFuture ? 0.75 : 1)
            Text(day.weekdayInitial)
                .font(Design.Typeface.eyebrow)
                .foregroundStyle(day.isToday ? Design.Color.ember : Design.Color.textTertiary)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let marker = day.marker {
            Text(marker)
                .font(Design.Typeface.numeral(.subheadline, weight: .bold))
                .foregroundStyle(day.trained ? Design.Color.onEmber : Design.Color.textPrimary)
        } else if let symbol = day.symbolName {
            Image(systemName: symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(day.trained ? Design.Color.onEmber : Design.Color.textSecondary)
        }
    }
}

// MARK: - Next up

/// The plan's next session: every lift with today's number (ember where the
/// weight goes up), "Log session" (voice, through the capture bar) and a
/// quiet way to type it or add a screenshot instead.
struct NextSessionCard: View {
    let session: TrainingSession
    let targets: [LiftTarget]
    let onLog: () -> Void
    let onType: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Next up").eyebrowStyle(Design.Color.ember)
                    Text(session.name)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Design.Color.textPrimary)
                }
                Spacer(minLength: 8)
                if let minutes = session.estMinutes {
                    Text("~\(minutes) min")
                        .font(Design.Typeface.numeral(.footnote, weight: .medium))
                        .foregroundStyle(Design.Color.textTertiary)
                }
            }
            VStack(spacing: 11) {
                ForEach(targets) { target in
                    LiftTargetRow(target: target)
                }
            }
            HStack(spacing: 8) {
                Button(action: onLog) {
                    Label("Log session", systemImage: "mic.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                Button(action: onType) {
                    Image(systemName: "keyboard")
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityLabel("Type it or add a screenshot")
            }
        }
        .padding(16)
        .cardSurface()
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
                Spacer(minLength: 8)
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
            .foregroundStyle(Design.Color.textPrimary)
    }
}

extension TrainValueRow where Trailing == Text {
    /// The common case: numbers as one rounded, tabular string.
    init(_ name: String, value: String, color: Color = Design.Color.textSecondary) {
        self.init(name) {
            Text(value)
                .font(Design.Typeface.numeral(.subheadline, weight: .semibold))
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
            color: target.addsWeight ? Design.Color.ember : Design.Color.textPrimary)
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

/// Today's plan session once it's logged: the lifts as done (ember where a
/// PR landed). While it's read, one calm shimmering line.
struct LoggedSessionCard: View {
    let activity: Activity
    var sessionName: String?
    var units: String = "imperial"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Today").eyebrowStyle(Design.Color.ember)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(sessionName ?? activity.title)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(Design.Color.textPrimary)
                        if !activity.prs.isEmpty { TrainPRBadge(count: activity.prs.count) }
                    }
                }
                Spacer(minLength: 8)
                if !activity.isProcessing, let minutes = activity.durationMin, minutes > 0 {
                    Text(ActivitySummaryFormatter.durationText(minutes: minutes))
                        .font(Design.Typeface.numeral(.footnote, weight: .medium))
                        .foregroundStyle(Design.Color.textTertiary)
                }
            }
            if activity.isProcessing {
                Text(ActivityCard.readingLine(for: activity))
                    .font(.subheadline)
                    .foregroundStyle(Design.Color.textSecondary)
                    .lineLimit(2)
                    .shimmering()
            } else {
                let prNames = Set(activity.prs.map { LiftIdentity.normalizedName($0.exercise) })
                VStack(spacing: 11) {
                    ForEach(Array(activity.exercises.filter { !$0.workingSets.isEmpty }.enumerated()), id: \.offset) { _, exercise in
                        let isPR = prNames.contains(LiftIdentity.normalizedName(exercise.name))
                        TrainValueRow(
                            ActivitySummaryFormatter.shortLiftName(exercise.name),
                            value: ActivitySummaryFormatter.exerciseSummary(exercise, units: units),
                            color: isPR ? Design.Color.ember : Design.Color.textSecondary)
                            .accessibilityElement(children: .combine)
                            .accessibilityValue(isPR ? "Personal record" : "")
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}

// MARK: - Plan states

struct EmptyPlanCard: View {
    let onBuild: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                CoachAvatar(size: 36)
                Text("No plan yet")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Design.Color.textPrimary)
            }
            Button(action: onBuild) {
                Text("Build my plan")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(16)
        .cardSurface()
    }
}

/// A plan Shudo drafted: what changed, run it or change it. Tapping the
/// card opens the full plan.
struct DraftPlanCard: View {
    let plan: TrainingPlan
    var isActivating: Bool
    let onRun: () -> Void
    let onChange: () -> Void
    let onDetails: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: onDetails) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("New plan").eyebrowStyle(Design.Color.honey)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(plan.plan.name)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(Design.Color.textPrimary)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(Design.Color.textTertiary)
                    }
                    if let summary = plan.changeSummary ?? plan.rationale {
                        Text(summary)
                            .font(.subheadline)
                            .foregroundStyle(Design.Color.textSecondary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows the whole plan")
            HStack(spacing: 8) {
                Button(action: onRun) {
                    HStack(spacing: 6) {
                        if isActivating { ProgressView().tint(Design.Color.onEmber) }
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
        .padding(16)
        .cardSurface()
        .overlay(
            RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
                .stroke(Design.Color.honey.opacity(0.4), lineWidth: 1))
    }
}

// MARK: - PR board

struct PRBoardCard: View {
    let bests: [PersonalBest]
    var units: String = "imperial"
    @State private var expanded = false
    static let collapsedCount = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("PR board").eyebrowStyle()
                Spacer()
                Text("e1RM").eyebrowStyle()
                    .accessibilityLabel("Estimated one-rep max")
            }
            let visible = expanded ? bests : Array(bests.prefix(Self.collapsedCount))
            VStack(spacing: 14) {
                ForEach(visible) { best in
                    PRBoardRow(best: best, units: units)
                }
            }
            if bests.count > Self.collapsedCount {
                Button(expanded ? "Show less" : "Show all \(bests.count)") {
                    withAnimation(Design.Motion.snap) { expanded.toggle() }
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Design.Color.textSecondary)
            }
        }
        .padding(16)
        .cardSurface()
    }
}

/// One lift: the set that earned it underneath, the estimated max on the
/// right — ember when it moved this week.
struct PRBoardRow: View {
    let best: PersonalBest
    var units: String

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ActivitySummaryFormatter.shortLiftName(best.name))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Design.Color.textPrimary)
                    .lineLimit(1)
                Text(ActivitySummaryFormatter.setText(best.bestSet, units: units))
                    .font(Design.Typeface.numeral(.caption, weight: .regular))
                    .foregroundStyle(Design.Color.textTertiary)
                    .monospacedDigit()
            }
            Spacer(minLength: 8)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                if let pounds = best.e1rmPounds {
                    let unit = WeightUnit(preference: units)
                    Text(Int(StrengthMath.convert(pounds: pounds, to: unit).rounded()).formatted())
                        .font(Design.Typeface.numeral(.title3, weight: .bold))
                        .foregroundStyle(best.isFresh ? Design.Color.ember : Design.Color.textPrimary)
                        .monospacedDigit()
                    Text(unit.rawValue)
                        .font(Design.Typeface.meta)
                        .foregroundStyle(Design.Color.textTertiary)
                } else {
                    Text("\(best.bestSet.reps)")
                        .font(Design.Typeface.numeral(.title3, weight: .bold))
                        .foregroundStyle(best.isFresh ? Design.Color.ember : Design.Color.textPrimary)
                        .monospacedDigit()
                    Text("reps")
                        .font(Design.Typeface.meta)
                        .foregroundStyle(Design.Color.textTertiary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(best.isFresh ? "New this week" : "")
    }
}

// MARK: - Plan detail sheet

struct TrainingPlanSheet: View {
    let plan: TrainingPlan
    var isActivating = false
    var onRun: (() -> Void)?
    var onChange: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        if plan.status == .draft {
                            Text("Draft").eyebrowStyle(Design.Color.honey)
                        }
                        Text(plan.plan.name)
                            .font(Design.Typeface.screenTitle)
                            .foregroundStyle(Design.Color.textPrimary)
                        Text("\(plan.plan.sessionsPerWeek) days a week")
                            .font(.subheadline)
                            .foregroundStyle(Design.Color.textSecondary)
                    }
                    ForEach(plan.plan.orderedSessions) { session in
                        sessionCard(session)
                    }
                    if let conditioning = plan.plan.conditioning {
                        Label(conditioning.summary, systemImage: "figure.outdoor.cycle")
                            .font(.subheadline)
                            .foregroundStyle(Design.Color.textSecondary)
                            .padding(.horizontal, 4)
                    }
                    VStack(spacing: 8) {
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
                    .padding(.top, 4)
                }
                .padding(16)
            }
            .background(Design.Color.canvas.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDragIndicator(.visible)
    }

    private func sessionCard(_ session: TrainingSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(session.name)
                    .font(.headline)
                    .foregroundStyle(Design.Color.textPrimary)
                if let focus = session.focus {
                    Text(focus)
                        .font(.footnote)
                        .foregroundStyle(Design.Color.textTertiary)
                        .lineLimit(1)
                }
                Spacer()
                if let minutes = session.estMinutes {
                    Text("~\(minutes) min")
                        .font(Design.Typeface.numeral(.caption, weight: .medium))
                        .foregroundStyle(Design.Color.textTertiary)
                }
            }
            ForEach(Array(session.exercises.enumerated()), id: \.offset) { _, exercise in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(exercise.name)
                            .font(.subheadline)
                            .foregroundStyle(Design.Color.textPrimary)
                        Spacer(minLength: 8)
                        Text(exercise.prescription)
                            .font(Design.Typeface.numeral(.subheadline, weight: .semibold))
                            .foregroundStyle(Design.Color.textPrimary)
                            .monospacedDigit()
                    }
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
        .padding(14)
        .cardSurface()
    }

    static func restText(_ seconds: Int) -> String {
        seconds >= 60 && seconds % 60 == 0 ? "\(seconds / 60) min"
            : seconds > 60 ? "\(seconds / 60):\(String(format: "%02d", seconds % 60))" : "\(seconds)s"
    }
}
