import MapKit
import SwiftUI

// MARK: - Rich cards inside the coach thread
//
// Shared chrome: opaque surface1, 22pt continuous corners, one width for
// the whole column. The bubble above a card says *why*; the card holds the
// one thing to look at or act on, so it carries no explainer copy and at
// most one prominent button. An eyebrow appears only where the card is a
// document worth naming (game plan, recap, a store run, new targets).

struct ThreadCard<Content: View>: View {
    var eyebrow: String?
    var accent: Color = Design.Color.ember
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let eyebrow {
                Text(eyebrow)
                    .eyebrowStyle(accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            content
        }
        .padding(16)
        .frame(width: Design.Layout.threadCardWidth, alignment: .leading)
        .cardSurface(radius: Design.Radius.card)
    }
}

/// What the cards can ask the screen to do.
struct ThreadCardActions {
    var act: (CoachCardAction) async -> Bool
    var isActing: (UUID) -> Bool
    /// Send a follow-up to Shudo ("Swap it", "Change it").
    var send: (String) -> Void
    var openTab: (AppTab) -> Void
    var openBio: () -> Void
    var openActivity: (UUID) -> Void
    /// Targets changed (goal card applied/undone): refresh the profile.
    var targetsChanged: () -> Void
    /// "Log it" logged a meal server-side: reload the day's meals.
    var mealLogged: () -> Void
}

struct CardButtonStyle: ButtonStyle {
    var prominent: Bool
    var fills = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(prominent ? Design.Color.onEmber : Design.Color.textPrimary)
            .frame(maxWidth: fills ? .infinity : nil)
            .frame(height: 40)
            .padding(.horizontal, fills ? 0 : 16)
            .background(prominent ? Design.Color.ember : Design.Color.surface3, in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

/// A settled outcome ("Logged", "Applied"), quiet and green.
private struct DoneLabel: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Design.Color.positive)
    }
}

/// A trailing text action ("Undo", "Open Train").
private struct CardLink: View {
    let title: String
    var color: Color = Design.Color.ember
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(color)
            .buttonStyle(.plain)
            .contentShape(Rectangle().inset(by: -10))
    }
}

// MARK: - Game plan (`plan`)

struct GamePlanCardView: View {
    let card: PlanCard

    var body: some View {
        ThreadCard(eyebrow: "Game plan") {
            if let theme = card.theme, !theme.isEmpty {
                Text(theme)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Design.Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !card.actions.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(card.actions.enumerated()), id: \.offset) { _, action in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: ThreadCardCopy.planSymbol(for: action))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Design.Color.honey)
                                .frame(width: 16)
                                .accessibilityHidden(true)
                            Text(action)
                                .font(.subheadline)
                                .foregroundStyle(Design.Color.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
    }
}

/// "+67 P" style pill.
struct MacroChip: View {
    let value: String
    let unit: String
    let color: Color

    var body: some View {
        HStack(spacing: 2) {
            Text(value).foregroundStyle(Design.Color.textPrimary)
            Text(unit).foregroundStyle(color)
        }
        .font(Design.Typeface.numeral(.caption, weight: .bold))
        .monospacedDigit()
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(color.opacity(0.12), in: Capsule())
    }
}

// MARK: - Recap (`recap`)

struct RecapCardView: View {
    let card: RecapCard
    let eyebrow: String
    let actions: ThreadCardActions

    var body: some View {
        ThreadCard(eyebrow: eyebrow) {
            if let headline = card.headline, !headline.isEmpty {
                Text(headline)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Design.Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let kcal = card.kcal {
                HStack(spacing: 14) {
                    MacroRings(
                        kcal: DayHeaderMath.progress(kcal, card.kcalTarget ?? 0),
                        protein: DayHeaderMath.progress(card.proteinG ?? 0, card.proteinTargetG ?? 0),
                        size: 48
                    )
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        stat(
                            Int(kcal.rounded()).formatted(),
                            card.kcalTarget.map { "of \(Int($0.rounded()).formatted()) kcal" } ?? "kcal"
                        )
                        if let protein = card.proteinG {
                            stat(
                                "\(Int(protein.rounded()))g",
                                ThreadCardCopy.proteinVerdict(protein: protein, target: card.proteinTargetG ?? 0)
                            )
                        }
                    }
                }
                .padding(.top, 2)
            }
            if card.period == .week {
                Button {
                    actions.openTab(.body)
                } label: {
                    Label("Open the recap", systemImage: "arrow.up.right")
                }
                .buttonStyle(CardButtonStyle(prominent: false, fills: false))
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(value)
                .font(Design.Typeface.numeral(.subheadline, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Design.Color.textPrimary)
            Text(label)
                .font(.caption)
                .foregroundStyle(Design.Color.textTertiary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Snack recommendation (`snack_rec`)

/// Where, what, and what it does for the day. Directions is the one
/// prominent action; "Log it" logs it once he has it; "Swap it" lives in
/// the long-press menu (or he just asks).
struct SnackRecCardView: View {
    let message: CoachMessage
    let card: SnackRec
    /// The plan has a lift later today (wording only).
    var liftLater = false
    let actions: ThreadCardActions

    @Environment(\.openURL) private var openURL
    @State private var confirmedGrab = false

    private var option: SnackRec.Option? { card.options.first }
    private var status: String? { message.rawPayload["status"]?.stringValue }
    private var isLogged: Bool { status == "logged" || confirmedGrab }

    var body: some View {
        ThreadCard(eyebrow: ThreadCardCopy.snackEyebrow(option)) {
            if card.verdict == .noSnackNeeded || option == nil {
                Text(card.headline.isEmpty ? "You're covered. No snack needed." : card.headline)
                    .font(.headline)
                    .foregroundStyle(Design.Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let option {
                Text(ThreadCardCopy.snackTitle(option))
                    .font(.headline)
                    .foregroundStyle(Design.Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    MacroChip(value: "+\(Int(option.combined.proteinG.rounded()))", unit: "P", color: Design.Color.macroProtein)
                    MacroChip(value: "+\(Int(option.combined.caloriesKcal.rounded()))", unit: "kcal", color: Design.Color.cream)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    "Adds \(Int(option.combined.proteinG.rounded())) grams protein, \(Int(option.combined.caloriesKcal.rounded())) kilocalories"
                )
                Text(ThreadCardCopy.snackPayoff(remainingAfter: option.remainingAfter, beforeLift: liftLater))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Design.Color.honey)
                    .fixedSize(horizontal: false, vertical: true)
                buttons(option)
                    .padding(.top, 2)
            }
        }
        .contextMenu {
            if let option, !isLogged {
                Button("Swap it", systemImage: "arrow.triangle.2.circlepath") {
                    actions.send("Swap it — what else is there instead of \(ThreadCardCopy.snackTitle(option))?")
                }
            }
        }
        .sensoryFeedback(.success, trigger: confirmedGrab)
    }

    @ViewBuilder
    private func buttons(_ option: SnackRec.Option) -> some View {
        if isLogged {
            DoneLabel(text: "Logged")
        } else {
            HStack(spacing: 8) {
                if ThreadCardCopy.hasDirections(option) {
                    Button {
                        openDirections(option)
                    } label: {
                        Label("Directions", systemImage: "arrow.up.right")
                    }
                    .buttonStyle(CardButtonStyle(prominent: true))
                }
                Button {
                    Task {
                        let done = await actions.act(.nearby(messageId: message.id, decision: .apply))
                        if done {
                            confirmedGrab = true
                            actions.mealLogged()
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if actions.isActing(message.id) {
                            ProgressView().controlSize(.small).tint(Design.Color.textPrimary)
                        }
                        Text("Log it")
                    }
                }
                .buttonStyle(CardButtonStyle(prominent: false, fills: !ThreadCardCopy.hasDirections(option)))
                .disabled(actions.isActing(message.id))
                .accessibilityLabel("I grabbed it, log it")
            }
        }
    }

    private func openDirections(_ option: SnackRec.Option) {
        Task { @MainActor in
            if let identifier = NearbyStoreScout.shared.mapItemIdentifier(forRef: option.storeRef),
               let item = try? await MKMapItemRequest(mapItemIdentifier: identifier).mapItem {
                item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
                return
            }
            let query = option.mapsQuery.isEmpty ? option.storeName : option.mapsQuery
            var components = URLComponents(string: "https://maps.apple.com/")
            components?.queryItems = [
                URLQueryItem(name: "daddr", value: query),
                URLQueryItem(name: "dirflg", value: "w"),
            ]
            if let url = components?.url { openURL(url) }
        }
    }
}

// MARK: - Training plan (`training_plan`)

struct TrainingPlanCardView: View {
    let card: TrainingPlanCard
    let actions: ThreadCardActions

    var body: some View {
        ThreadCard(eyebrow: "Training plan") {
            Text(card.name)
                .font(.title3.weight(.bold))
                .foregroundStyle(Design.Color.textPrimary)
                .accessibilityLabel("\(card.name), \(card.sessionsPerWeek) days a week")
            if !card.sessions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(card.sessions.prefix(5).enumerated()), id: \.element.id) { index, session in
                        if index > 0 { HairlineRule() }
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(session.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Design.Color.textPrimary)
                            Spacer(minLength: 6)
                            Text(session.topExercises.prefix(2).joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(Design.Color.textTertiary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 8)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            switch card.status {
            case .draft:
                HStack(spacing: 8) {
                    Button {
                        Task { _ = await actions.act(.trainingPlan(card, decision: .activate)) }
                    } label: {
                        HStack(spacing: 6) {
                            if actions.isActing(card.planId) {
                                ProgressView().controlSize(.small).tint(Design.Color.onEmber)
                            }
                            Text("Run it")
                        }
                    }
                    .buttonStyle(CardButtonStyle(prominent: true))
                    .disabled(actions.isActing(card.planId))
                    Button("Change it") { actions.send(TrainScreen.changeDraftPrompt) }
                        .buttonStyle(CardButtonStyle(prominent: false, fills: false))
                }
            case .active:
                HStack {
                    DoneLabel(text: "Active")
                    Spacer()
                    CardLink(title: "Open Train") { actions.openTab(.train) }
                }
            case .superseded, .rejected:
                Text(card.status == .rejected ? "Passed on this one" : "Replaced by a newer plan")
                    .font(.footnote)
                    .foregroundStyle(Design.Color.textTertiary)
            }
        }
    }
}

// MARK: - Goal change (`goal_change`)

struct GoalChangeCardView: View {
    let card: GoalChangeCard
    let units: String
    let actions: ThreadCardActions

    var body: some View {
        ThreadCard(eyebrow: "New targets") {
            VStack(spacing: 0) {
                row("Calories", card.before.caloriesKcal, card.after.caloriesKcal, unit: "kcal")
                row("Protein", card.before.proteinG, card.after.proteinG, unit: "g")
                row("Carbs", card.before.carbsG, card.after.carbsG, unit: "g")
                row("Fat", card.before.fatG, card.after.fatG, unit: "g")
                if let goal = ThreadCardCopy.goalLabel(card.after.goalType),
                   card.after.goalType != card.before.goalType {
                    textRow("Goal", ThreadCardCopy.goalLabel(card.before.goalType), goal)
                }
                if let weight = card.after.targetWeightKg, weight != card.before.targetWeightKg {
                    textRow("Goal weight", card.before.targetWeightKg.map(weightText), weightText(weight))
                }
            }
            if let date = card.projectedGoalDate ?? card.after.goalDate {
                Text("On pace for \(prettyDate(date))")
                    .font(.footnote)
                    .foregroundStyle(Design.Color.textSecondary)
            }
            ForEach(card.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Design.Color.honey)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch card.status {
            case .needsConfirmation:
                HStack(spacing: 8) {
                    Button {
                        Task {
                            if await actions.act(.goalChange(card, decision: .apply)) { actions.targetsChanged() }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if actions.isActing(card.changeId) {
                                ProgressView().controlSize(.small).tint(Design.Color.onEmber)
                            }
                            Text("Apply")
                        }
                    }
                    .buttonStyle(CardButtonStyle(prominent: true))
                    Button("Keep current") {
                        Task { _ = await actions.act(.goalChange(card, decision: .discard)) }
                    }
                    .buttonStyle(CardButtonStyle(prominent: false))
                }
                .disabled(actions.isActing(card.changeId))
            case .applied:
                HStack {
                    DoneLabel(text: "Applied")
                    Spacer()
                    CardLink(title: "Undo") {
                        Task {
                            if await actions.act(.goalChange(card, decision: .undo)) { actions.targetsChanged() }
                        }
                    }
                    .disabled(actions.isActing(card.changeId))
                }
            case .undone, .discarded, .rejected:
                Text("Kept your current targets")
                    .font(.footnote)
                    .foregroundStyle(Design.Color.textTertiary)
            }
        }
    }

    /// Only what moved; an unchanged macro is noise on a "what changed" card.
    @ViewBuilder
    private func row(_ label: String, _ before: Double?, _ after: Double?, unit: String) -> some View {
        if let after, before.map({ Int($0.rounded()) != Int(after.rounded()) }) ?? true {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(Design.Color.textSecondary)
                Spacer()
                if let before {
                    Text(Int(before.rounded()).formatted())
                        .foregroundStyle(Design.Color.textTertiary)
                    Image(systemName: "arrow.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Design.Color.textTertiary)
                        .accessibilityLabel("to")
                }
                Text("\(Int(after.rounded()).formatted()) \(unit)")
                    .foregroundStyle(Design.Color.textPrimary)
            }
            .font(Design.Typeface.numeral(.subheadline, weight: .semibold))
            .monospacedDigit()
            .padding(.vertical, 5)
            .accessibilityElement(children: .combine)
        }
    }

    private func textRow(_ label: String, _ before: String?, _ after: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Design.Color.textSecondary)
            Spacer()
            if let before {
                Text(before)
                    .font(.subheadline)
                    .foregroundStyle(Design.Color.textTertiary)
                Image(systemName: "arrow.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Design.Color.textTertiary)
                    .accessibilityLabel("to")
            }
            Text(after)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Design.Color.textPrimary)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }

    private func weightText(_ kilograms: Double) -> String {
        let value = BodyUnits.display(kilograms, units: units)
        return "\(String(format: "%.1f", value)) \(BodyUnits.label(units))"
    }

    private func prettyDate(_ localDay: String) -> String {
        guard let date = LocalDayMath.date(localDay) else { return localDay }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: date)
    }
}

// MARK: - Bio update (`profile_update`)

/// The bubble already says "Updated your bio"; the card is just what
/// changed, with Undo and a way into the bio.
struct ProfileUpdateCardView: View {
    let message: CoachMessage
    let card: ProfileUpdateCard
    let actions: ThreadCardActions

    var body: some View {
        ThreadCard {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(card.changes) { change in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: symbol(change.op))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Design.Color.honey)
                            .frame(width: 14)
                            .accessibilityHidden(true)
                        Text(change.summary)
                            .font(.subheadline)
                            .foregroundStyle(card.isUndone ? Design.Color.textTertiary : Design.Color.textPrimary)
                            .strikethrough(card.isUndone, color: Design.Color.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack {
                if card.isUndone {
                    Text("Undone")
                        .font(.footnote)
                        .foregroundStyle(Design.Color.textTertiary)
                } else if card.undoVersion != nil {
                    CardLink(title: "Undo") {
                        Task { _ = await actions.act(.bioUpdate(messageId: message.id, decision: .undo)) }
                    }
                    .disabled(actions.isActing(message.id))
                }
                Spacer()
                Button {
                    actions.openBio()
                } label: {
                    HStack(spacing: 3) {
                        Text("Your bio")
                        Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                    }
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Design.Color.textSecondary)
                .buttonStyle(.plain)
            }
            .padding(.top, 2)
        }
    }

    private func symbol(_ op: ProfileUpdateCard.Change.Operation) -> String {
        switch op {
        case .add: return "plus"
        case .replace: return "pencil"
        case .remove: return "minus"
        }
    }
}

// MARK: - Personal records (`workout_ack`)

/// Only the PRs: the workout itself is the receipt just above, and the
/// bubble says the rest. Tap through to the session.
struct WorkoutAckCardView: View {
    let card: WorkoutAckCard
    let actions: ThreadCardActions

    var body: some View {
        Button {
            if let id = card.activityId { actions.openActivity(id) }
        } label: {
            ThreadCard(eyebrow: card.prs.count > 1 ? "\(card.prs.count) new PRs" : "New PR") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(card.prs) { record in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(record.exercise)
                                .font(.subheadline)
                                .foregroundStyle(Design.Color.textPrimary)
                                .lineLimit(1)
                            Spacer(minLength: 6)
                            Text(ThreadCardCopy.prValue(record))
                                .font(Design.Typeface.numeral(.headline, weight: .bold))
                                .foregroundStyle(Design.Color.textPrimary)
                                .monospacedDigit()
                            if let delta = ThreadCardCopy.prDelta(record) {
                                Text(delta)
                                    .font(Design.Typeface.numeral(.caption, weight: .bold))
                                    .foregroundStyle(Design.Color.ember)
                                    .monospacedDigit()
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(card.activityId == nil)
        .sensoryFeedback(.success, trigger: card.prs.count)
    }
}

// MARK: - Physique review (`photo_feedback`)

struct PhysiqueReviewCardView: View {
    let review: CheckInCard.Review

    var body: some View {
        ThreadCard {
            if !review.headline.isEmpty {
                Text(review.headline)
                    .font(.headline)
                    .foregroundStyle(Design.Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(review.observations.prefix(3), id: \.self) { observation in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(Design.Color.honey).frame(width: 4, height: 4)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                    Text(observation)
                        .font(.subheadline)
                        .foregroundStyle(Design.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
