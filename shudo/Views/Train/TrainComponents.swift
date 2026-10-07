import SwiftUI

// MARK: - Week header: plan name, the 7-day strip, sessions-vs-target ring

struct TrainWeekHeader: View {
    let planName: String?
    let week: TrainingWeekProgress
    var onOpenPlan: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 4) {
                        Text(eyebrow).eyebrowStyle()
                            .lineLimit(1)
                        if onOpenPlan != nil {
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.heavy))
                                .foregroundStyle(Design.Color.textTertiary)
                        }
                    }
                    Text(week.summary)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Design.Color.textPrimary)
                        .contentTransition(.numericText(value: Double(week.completed)))
                }
                Spacer(minLength: 8)
                TrainWeekRing(completed: week.completed, target: week.target, fraction: week.fraction)
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
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(onOpenPlan == nil ? [] : .isButton)
        .accessibilityHint(onOpenPlan == nil ? "" : "Opens your training plan")
    }

    private var eyebrow: String {
        guard let planName else { return "This week" }
        if let target = week.target { return "\(planName) · \(target) days" }
        return planName
    }
}

struct TrainWeekRing: View {
    let completed: Int
    let target: Int?
    let fraction: Double
    var size: CGFloat = 58
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let lineWidth = size * 0.11
        ZStack {
            Circle().stroke(Design.Color.ember.opacity(0.16), lineWidth: lineWidth)
            RingArc(progress: fraction)
                .stroke(Design.Color.ember, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .shadow(color: Design.Color.ember.opacity(fraction >= 1 ? 0.6 : 0), radius: 6)
                .animation(Design.Motion.gated(Design.Motion.ring, reduceMotion: reduceMotion), value: fraction)
            VStack(spacing: -2) {
                Text("\(completed)")
                    .font(Design.Typeface.numeral(.title3, weight: .bold))
                    .foregroundStyle(Design.Color.textPrimary)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(completed)))
                if let target {
                    Text("of \(target)")
                        .font(Design.Typeface.meta)
                        .foregroundStyle(Design.Color.textTertiary)
                        .monospacedDigit()
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(target.map { "\(completed) of \($0) sessions this week" } ?? "\(completed) sessions this week")
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
        } else if !day.isFuture {
            Text("—")
                .font(Design.Typeface.numeral(.subheadline, weight: .bold))
                .foregroundStyle(Design.Color.textTertiary)
        }
    }
}

// MARK: - Next up

struct NextSessionCard: View {
    let session: TrainingSession
    let targets: [LiftTarget]
    var eyebrow = "Next up"
    var isSecondary = false
    let onLog: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "dumbbell.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Design.Color.ember)
                Text(eyebrow).eyebrowStyle(Design.Color.ember)
                Spacer()
                if let minutes = session.estMinutes {
                    Label("~\(minutes) min", systemImage: "timer")
                        .labelStyle(TrainInlineLabelStyle())
                        .font(Design.Typeface.numeral(.caption, weight: .semibold))
                        .foregroundStyle(Design.Color.textTertiary)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(session.name)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Design.Color.textPrimary)
                if let focus = session.focus {
                    Text(focus.prefix(1).uppercased() + focus.dropFirst())
                        .font(.subheadline)
                        .foregroundStyle(Design.Color.textSecondary)
                }
            }
            VStack(spacing: 12) {
                ForEach(targets.prefix(3)) { target in
                    LiftTargetRow(target: target)
                }
            }
            if targets.count > 3 {
                Text("+\(targets.count - 3) more · \(targets.dropFirst(3).map { ActivitySummaryFormatter.shortLiftName($0.exercise.name) }.joined(separator: ", "))")
                    .font(.footnote)
                    .foregroundStyle(Design.Color.textTertiary)
                    .lineLimit(1)
            }
            Button(action: onLog) {
                Label("Log session", systemImage: "mic.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(isSecondary ? AnyTrainButtonStyle(SecondaryButtonStyle()) : AnyTrainButtonStyle(PrimaryButtonStyle()))
        }
        .padding(16)
        .cardSurface()
    }
}

/// Type-erased button style so a card can switch prominence.
struct AnyTrainButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: ButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}

struct LiftTargetRow: View {
    let target: LiftTarget

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ActivitySummaryFormatter.shortLiftName(target.exercise.name))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Design.Color.textPrimary)
                    .lineLimit(1)
                Text(target.lastSummary ?? "First time — find a weight you own")
                    .font(Design.Typeface.numeral(.caption, weight: .regular))
                    .foregroundStyle(Design.Color.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if let delta = target.deltaLabel {
                Text(delta)
                    .font(Design.Typeface.numeral(.caption2, weight: .bold))
                    .foregroundStyle(Design.Color.ember)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Design.Color.ember.opacity(0.14), in: Capsule())
            }
            Text(target.prescription)
                .font(Design.Typeface.numeral(.subheadline, weight: .semibold))
                .foregroundStyle(Design.Color.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Logged today

struct LoggedSessionCard: View {
    let activity: Activity
    var sessionName: String?
    var units: String = "imperial"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: activity.isProcessing ? "dumbbell.fill" : "checkmark.seal.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Design.Color.ember)
                Text("\(sessionName ?? activity.title) · \(activity.isProcessing ? "reading" : "logged")")
                    .eyebrowStyle(Design.Color.ember)
                Spacer()
                if !activity.prs.isEmpty { TrainPRBadge(count: activity.prs.count) }
            }
            if activity.isProcessing {
                Text(activity.analysisPreview ?? "Reading your session…")
                    .font(.subheadline)
                    .foregroundStyle(Design.Color.textSecondary)
                    .shimmering()
            } else {
                let prNames = Set(activity.prs.map { LiftIdentity.normalizedName($0.exercise) })
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(activity.exercises.filter { !$0.workingSets.isEmpty }.prefix(4).enumerated()), id: \.offset) { _, exercise in
                        HStack(spacing: 8) {
                            Text(ActivitySummaryFormatter.shortLiftName(exercise.name))
                                .font(.subheadline)
                                .foregroundStyle(Design.Color.textPrimary)
                                .lineLimit(1)
                            Spacer(minLength: 6)
                            if prNames.contains(LiftIdentity.normalizedName(exercise.name)) {
                                TrainPRBadge()
                            }
                            Text(ActivitySummaryFormatter.exerciseSummary(exercise, units: units))
                                .font(Design.Typeface.numeral(.subheadline))
                                .monospacedDigit()
                                .foregroundStyle(Design.Color.textSecondary)
                                .fixedSize()
                        }
                    }
                }
            }
            let footer = [
                activity.durationMin.map { ActivitySummaryFormatter.durationText(minutes: $0) },
                activity.activeKcal.map { "~\(Int($0.rounded())) kcal" },
            ].compactMap { $0 }
            if !footer.isEmpty, !activity.isProcessing {
                Text(footer.joined(separator: " · "))
                    .font(Design.Typeface.numeral(.caption, weight: .medium))
                    .foregroundStyle(Design.Color.textTertiary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .overlay(
            RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
                .stroke(Design.Color.ember.opacity(0.35), lineWidth: 1))
    }
}

// MARK: - Plan states

struct EmptyPlanCard: View {
    let onBuild: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                CoachAvatar(size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text("No plan yet")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Design.Color.textPrimary)
                    Text("Tell Shudo to build you one — fit to your work week, built for the bulk, with numbers to beat every session.")
                        .font(.subheadline)
                        .foregroundStyle(Design.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button(action: onBuild) {
                Label("Build my plan", systemImage: "list.bullet.clipboard.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(16)
        .cardSurface()
    }
}

struct DraftPlanCard: View {
    let plan: TrainingPlan
    var isActivating: Bool
    let onRun: () -> Void
    let onChange: () -> Void
    let onDetails: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.clipboard.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Design.Color.honey)
                Text("New plan · draft").eyebrowStyle(Design.Color.honey)
            }
            Text(plan.plan.name)
                .font(.title3.weight(.bold))
                .foregroundStyle(Design.Color.textPrimary)
            if let summary = plan.changeSummary ?? plan.rationale {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(Design.Color.textSecondary)
                    .lineLimit(4)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(plan.plan.orderedSessions) { session in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(session.name)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Design.Color.textPrimary)
                            .frame(width: 70, alignment: .leading)
                        Text(session.exercises.prefix(3).map { ActivitySummaryFormatter.shortLiftName($0.name) }.joined(separator: ", "))
                            .font(.footnote)
                            .foregroundStyle(Design.Color.textTertiary)
                            .lineLimit(1)
                    }
                }
            }
            .onTapGesture(perform: onDetails)
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
                Button("Change it", action: onChange)
                    .buttonStyle(SecondaryButtonStyle())
                Button(action: onDetails) {
                    Image(systemName: "list.bullet")
                        .accessibilityLabel("Plan details")
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "trophy.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Design.Color.ember)
                Text("PR board").eyebrowStyle(Design.Color.ember)
                Spacer()
                Text("Est. 1RM").eyebrowStyle()
            }
            let visible = expanded ? bests : Array(bests.prefix(Self.collapsedCount))
            VStack(spacing: 0) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, best in
                    if index > 0 { HairlineRule().padding(.vertical, 9) }
                    PRBoardRow(best: best, units: units)
                }
            }
            if bests.count > Self.collapsedCount {
                Button(expanded ? "Show less" : "Show all \(bests.count)") {
                    withAnimation(Design.Motion.snap) { expanded.toggle() }
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Design.Color.ember)
            }
        }
        .padding(16)
        .cardSurface()
    }
}

struct PRBoardRow: View {
    let best: PersonalBest
    var units: String

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(ActivitySummaryFormatter.shortLiftName(best.name))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Design.Color.textPrimary)
                        .lineLimit(1)
                    if best.isFresh {
                        Image(systemName: "flame.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Design.Color.ember)
                            .accessibilityLabel("New this week")
                    }
                }
                Text("\(ActivitySummaryFormatter.setText(best.bestSet, units: units)) · \(TrainSnapshot.displayTitle(localDay: best.localDay))")
                    .font(Design.Typeface.numeral(.caption, weight: .regular))
                    .foregroundStyle(Design.Color.textTertiary)
            }
            Spacer(minLength: 8)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                if let pounds = best.e1rmPounds {
                    let unit = WeightUnit(preference: units)
                    Text(Int(StrengthMath.convert(pounds: pounds, to: unit).rounded()).formatted())
                        .font(Design.Typeface.numeral(.title3, weight: .bold))
                        .foregroundStyle(Design.Color.textPrimary)
                        .monospacedDigit()
                    Text(unit.rawValue)
                        .font(Design.Typeface.meta)
                        .foregroundStyle(Design.Color.textTertiary)
                } else {
                    Text("\(best.bestSet.reps)")
                        .font(Design.Typeface.numeral(.title3, weight: .bold))
                        .foregroundStyle(Design.Color.textPrimary)
                        .monospacedDigit()
                    Text("reps")
                        .font(Design.Typeface.meta)
                        .foregroundStyle(Design.Color.textTertiary)
                }
            }
        }
        .accessibilityElement(children: .combine)
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
                    VStack(alignment: .leading, spacing: 6) {
                        Text(plan.status == .draft ? "Draft" : "Active plan").eyebrowStyle(Design.Color.ember)
                        Text(plan.plan.name)
                            .font(Design.Typeface.screenTitle)
                            .foregroundStyle(Design.Color.textPrimary)
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(Design.Color.textSecondary)
                        if let rationale = plan.rationale {
                            Text(rationale)
                                .font(.footnote)
                                .foregroundStyle(Design.Color.textTertiary)
                                .padding(.top, 4)
                        }
                    }
                    ForEach(plan.plan.orderedSessions) { session in
                        sessionCard(session)
                    }
                    if let conditioning = plan.plan.conditioning {
                        infoCard(title: "Conditioning", symbol: "figure.outdoor.cycle", text: conditioning.summary)
                    }
                    if let notes = plan.plan.notes {
                        infoCard(title: "Notes", symbol: "text.quote", text: notes)
                    }
                    if !plan.plan.equipmentAssumed.isEmpty {
                        infoCard(
                            title: "Equipment", symbol: "dumbbell",
                            text: plan.plan.equipmentAssumed.joined(separator: " · "))
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
                            Text("Ask Shudo to change it").frame(maxWidth: .infinity)
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

    private var subtitle: String {
        var parts = ["\(plan.plan.sessionsPerWeek) sessions a week"]
        parts.append("rotation \(plan.plan.orderedSessions.map(\.name).joined(separator: " → "))")
        return parts.joined(separator: " · ")
    }

    private func sessionCard(_ session: TrainingSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(session.name)
                    .font(.headline)
                    .foregroundStyle(Design.Color.textPrimary)
                if let focus = session.focus {
                    Text(focus)
                        .font(.footnote)
                        .foregroundStyle(Design.Color.textTertiary)
                }
                Spacer()
                if let minutes = session.estMinutes {
                    Text("~\(minutes) min")
                        .font(Design.Typeface.numeral(.caption, weight: .semibold))
                        .foregroundStyle(Design.Color.textTertiary)
                }
            }
            ForEach(Array(session.exercises.enumerated()), id: \.offset) { index, exercise in
                if index > 0 { HairlineRule() }
                VStack(alignment: .leading, spacing: 3) {
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
                    let meta = [
                        exercise.restSec.map { "rest \(Self.restText($0))" },
                        exercise.incrementLb.map { "+\(StrengthMath.formatWeight($0)) lb when every set hits \(exercise.repMax)" },
                        exercise.cue,
                    ].compactMap { $0 }
                    if !meta.isEmpty {
                        Text(meta.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(Design.Color.textTertiary)
                    }
                }
            }
        }
        .padding(14)
        .cardSurface()
    }

    private func infoCard(title: String, symbol: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(Design.Typeface.eyebrow)
                .textCase(.uppercase)
                .foregroundStyle(Design.Color.textTertiary)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Design.Color.textSecondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    static func restText(_ seconds: Int) -> String {
        seconds >= 60 && seconds % 60 == 0 ? "\(seconds / 60) min"
            : seconds > 60 ? "\(seconds / 60):\(String(format: "%02d", seconds % 60))" : "\(seconds)s"
    }
}
