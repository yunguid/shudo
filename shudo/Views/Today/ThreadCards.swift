import MapKit
import SwiftUI

// MARK: - Rich cards inside the coach thread
//
// Shared chrome: opaque surface1, 22pt continuous corners, a stamped
// eyebrow, max width 300 so they read as "sent by Shudo", never as a
// dashboard. Numbers come from the card payloads (server-computed).

struct ThreadCard<Content: View>: View {
    let eyebrow: String
    let symbol: String
    var accent: Color = Design.Color.ember
    var maxWidth: CGFloat = 300
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(accent)
                Text(eyebrow).eyebrowStyle(accent)
            }
            .accessibilityElement(children: .combine)
            content
        }
        .padding(14)
        .frame(maxWidth: maxWidth, alignment: .leading)
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
    /// "I grabbed it" logged a meal server-side: reload the day's meals.
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

// MARK: - Game plan (`plan`)

struct GamePlanCardView: View {
    let card: PlanCard
    let localDay: String

    var body: some View {
        ThreadCard(eyebrow: ThreadCardCopy.planEyebrow(localDay: localDay), symbol: "list.bullet.clipboard.fill") {
            if let theme = card.theme, !theme.isEmpty {
                Text(theme)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Design.Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !card.actions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(card.actions.enumerated()), id: \.offset) { _, action in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: ThreadCardCopy.planSymbol(for: action))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Design.Color.honey)
                                .frame(width: 16)
                            Text(action)
                                .font(.subheadline)
                                .foregroundStyle(Design.Color.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if let remaining = card.remaining, remaining.caloriesKcal > 0 {
                HStack(spacing: 6) {
                    MacroChip(value: "\(Int(remaining.caloriesKcal.rounded()).formatted())", unit: "kcal", color: Design.Color.cream)
                    MacroChip(value: "\(Int(remaining.proteinG.rounded()))", unit: "P", color: Design.Color.macroProtein)
                    Text("to go")
                        .font(.caption)
                        .foregroundStyle(Design.Color.textTertiary)
                }
            }
        }
    }
}

/// "+84 P" style pill.
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
        ThreadCard(eyebrow: eyebrow, symbol: "flame.fill") {
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
                        size: 54
                    )
                    VStack(alignment: .leading, spacing: 6) {
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
                        if let score = card.score {
                            stat("\(Int(score.rounded()))", "day score")
                        }
                    }
                }
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
    }
}

// MARK: - Snack recommendation (`snack_rec`)

struct SnackRecCardView: View {
    let message: CoachMessage
    let card: SnackRec
    let target: MacroTarget
    /// The plan has a lift later today (wording only).
    var liftLater = false
    let actions: ThreadCardActions

    @Environment(\.openURL) private var openURL
    @State private var confirmedGrab = false

    private var option: SnackRec.Option? { card.options.first }
    private var status: String? { message.rawPayload["status"]?.stringValue }
    private var isLogged: Bool { status == "logged" || confirmedGrab }

    var body: some View {
        ThreadCard(eyebrow: ThreadCardCopy.snackEyebrow(option), symbol: option?.storeRef == "home" ? "house.fill" : "location.fill") {
            if card.verdict == .noSnackNeeded || option == nil {
                Text(card.headline.isEmpty ? "You're covered. No snack needed." : card.headline)
                    .font(.headline)
                    .foregroundStyle(Design.Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let option {
                VStack(alignment: .leading, spacing: 3) {
                    Text(ThreadCardCopy.snackTitle(option))
                        .font(.headline)
                        .foregroundStyle(Design.Color.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    let subtitle = ThreadCardCopy.snackSubtitle(option)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(Design.Color.textSecondary)
                    }
                }
                deltas(option.combined)
                HStack(spacing: 8) {
                    MacroRings(
                        kcal: projected(option, \.caloriesKcal, target: target.caloriesKcal),
                        protein: projected(option, \.proteinG, target: target.proteinG),
                        size: 22,
                        lineWidth: 3
                    )
                    Text(ThreadCardCopy.snackPayoff(remainingAfter: option.remainingAfter, beforeLift: liftLater))
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Design.Color.honey)
                        .fixedSize(horizontal: false, vertical: true)
                }
                buttons(option)
                if card.options.count > 1 {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(card.options.dropFirst().prefix(2)) { alternative in
                            Text("Or: \(ThreadCardCopy.snackTitle(alternative)) · \(alternative.storeName)")
                                .font(.caption)
                                .foregroundStyle(Design.Color.textTertiary)
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
        .sensoryFeedback(.success, trigger: confirmedGrab)
    }

    private func deltas(_ combined: CoachMacros) -> some View {
        HStack(spacing: 6) {
            MacroChip(value: "+\(Int(combined.proteinG.rounded()))", unit: "P", color: Design.Color.macroProtein)
            MacroChip(value: "+\(Int(combined.carbsG.rounded()))", unit: "C", color: Design.Color.macroCarbs)
            MacroChip(value: "+\(Int(combined.fatG.rounded()))", unit: "F", color: Design.Color.macroFat)
            MacroChip(value: "+\(Int(combined.caloriesKcal.rounded()))", unit: "kcal", color: Design.Color.cream)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Adds \(Int(combined.proteinG.rounded())) grams protein, \(Int(combined.caloriesKcal.rounded())) kilocalories"
        )
    }

    /// The day's rings after eating it (target − what would still be left).
    private func projected(_ option: SnackRec.Option, _ key: KeyPath<CoachMacros, Double>, target: Double) -> Double {
        DayHeaderMath.progress(target - max(0, option.remainingAfter[keyPath: key]), target)
    }

    @ViewBuilder
    private func buttons(_ option: SnackRec.Option) -> some View {
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
                actions.send("Swap it — what else is there instead of \(ThreadCardCopy.snackTitle(option))?")
            } label: {
                Text("Swap it")
            }
            .buttonStyle(CardButtonStyle(prominent: false, fills: !ThreadCardCopy.hasDirections(option)))
        }
        if isLogged {
            Label("Logged", systemImage: "checkmark.circle.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Design.Color.positive)
        } else {
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
                    Text("I grabbed it — log it")
                }
            }
            .buttonStyle(CardButtonStyle(prominent: false))
            .disabled(actions.isActing(message.id))
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
        ThreadCard(
            eyebrow: card.isActive ? "Training plan · active" : "Training plan · draft",
            symbol: "dumbbell.fill"
        ) {
            VStack(alignment: .leading, spacing: 3) {
                Text(card.name)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Design.Color.textPrimary)
                Text("\(card.sessionsPerWeek) days a week")
                    .font(.footnote)
                    .foregroundStyle(Design.Color.textTertiary)
            }
            if !card.summary.isEmpty {
                Text(card.summary)
                    .font(.subheadline)
                    .foregroundStyle(Design.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
                            if let minutes = session.estMinutes {
                                Text("\(minutes)m")
                                    .font(Design.Typeface.numeral(.caption, weight: .semibold))
                                    .foregroundStyle(Design.Color.textSecondary)
                                    .monospacedDigit()
                            }
                        }
                        .padding(.vertical, 7)
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
                            Text("Activate")
                        }
                    }
                    .buttonStyle(CardButtonStyle(prominent: true))
                    .disabled(actions.isActing(card.planId))
                    Button("Change it") { actions.send(TrainScreen.changeDraftPrompt) }
                        .buttonStyle(CardButtonStyle(prominent: false, fills: false))
                }
            case .active:
                HStack {
                    Label("Running this one", systemImage: "checkmark.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Design.Color.positive)
                    Spacer()
                    Button("Open Train") { actions.openTab(.train) }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Design.Color.ember)
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
        ThreadCard(eyebrow: "New targets", symbol: "target") {
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
                Label("On pace for \(prettyDate(date))", systemImage: "calendar")
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
                    Label("Applied", systemImage: "checkmark.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Design.Color.positive)
                    Spacer()
                    Button("Undo") {
                        Task {
                            if await actions.act(.goalChange(card, decision: .undo)) { actions.targetsChanged() }
                        }
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Design.Color.ember)
                    .disabled(actions.isActing(card.changeId))
                }
            case .undone, .discarded, .rejected:
                Text("Kept your current targets")
                    .font(.footnote)
                    .foregroundStyle(Design.Color.textTertiary)
            }
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ before: Double?, _ after: Double?, unit: String) -> some View {
        if let after {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(Design.Color.textSecondary)
                Spacer()
                if let before, Int(before.rounded()) != Int(after.rounded()) {
                    Text(Int(before.rounded()).formatted())
                        .strikethrough(color: Design.Color.textTertiary)
                        .foregroundStyle(Design.Color.textTertiary)
                    Image(systemName: "arrow.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Design.Color.textTertiary)
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
                    .strikethrough(color: Design.Color.textTertiary)
                    .foregroundStyle(Design.Color.textTertiary)
                Image(systemName: "arrow.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Design.Color.textTertiary)
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

struct ProfileUpdateCardView: View {
    let message: CoachMessage
    let card: ProfileUpdateCard
    let actions: ThreadCardActions

    var body: some View {
        ThreadCard(eyebrow: "Bio updated", symbol: "person.text.rectangle.fill") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(card.changes) { change in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: symbol(change.op))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Design.Color.ember)
                            .frame(width: 14)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(change.sectionTitle)
                                .eyebrowStyle()
                            Text(change.summary)
                                .font(.subheadline)
                                .foregroundStyle(card.isUndone ? Design.Color.textTertiary : Design.Color.textPrimary)
                                .strikethrough(card.isUndone, color: Design.Color.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            HStack {
                if card.isUndone {
                    Text("Undone")
                        .font(.footnote)
                        .foregroundStyle(Design.Color.textTertiary)
                } else if card.undoVersion != nil {
                    Button("Undo") {
                        Task { _ = await actions.act(.bioUpdate(messageId: message.id, decision: .undo)) }
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Design.Color.ember)
                    .disabled(actions.isActing(message.id))
                }
                Spacer()
                Button {
                    actions.openBio()
                } label: {
                    Label("Your bio", systemImage: "chevron.right")
                        .labelStyle(TrailingIconLabelStyle())
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Design.Color.textSecondary)
            }
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

struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.title
            configuration.icon.font(.caption2.weight(.bold))
        }
    }
}

// MARK: - Workout acknowledgement (`workout_ack`)

struct WorkoutAckCardView: View {
    let card: WorkoutAckCard
    let activity: Activity?
    let actions: ThreadCardActions

    var body: some View {
        Button {
            if let id = card.activityId { actions.openActivity(id) }
        } label: {
            ThreadCard(eyebrow: "\(activity?.title ?? "Workout") · logged", symbol: "dumbbell.fill") {
                if card.prs.isEmpty, let activity {
                    Text(ActivitySummaryFormatter.subtitle(for: activity, units: "imperial") ?? activity.title)
                        .font(.subheadline)
                        .foregroundStyle(Design.Color.textSecondary)
                }
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(card.prs) { record in
                        HStack(spacing: 8) {
                            Text(record.exercise)
                                .font(.subheadline)
                                .foregroundStyle(Design.Color.textPrimary)
                                .lineLimit(1)
                            Spacer(minLength: 6)
                            TrainPRBadge()
                            Text(ThreadCardCopy.prValue(record))
                                .font(Design.Typeface.numeral(.subheadline, weight: .semibold))
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
                if let activity, activity.status == .complete {
                    HStack(spacing: 8) {
                        if let duration = ActivitySummaryFormatter.metaDuration(for: activity) {
                            Text(duration)
                        }
                        if let kcal = activity.activeKcal, kcal >= 1 {
                            Text("~\(Int(kcal.rounded())) kcal burned")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(Design.Color.textTertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(card.activityId == nil)
        .sensoryFeedback(.success, trigger: card.prs.count)
    }
}

// MARK: - Check-in feedback (`weigh_in_ack`, `photo_feedback`)

struct CheckInFeedbackCardView: View {
    let card: CheckInCard
    let units: String

    var body: some View {
        ThreadCard(
            eyebrow: card.kind == .photoFeedback ? "Physique review" : "Weigh-in",
            symbol: card.kind == .photoFeedback ? "camera.aperture" : "scalemass.fill",
            accent: Design.Color.honey
        ) {
            if let weight = card.weightKg {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(String(format: "%.1f", BodyUnits.display(weight, units: units)))
                        .font(Design.Typeface.numeral(.title2, weight: .bold))
                        .foregroundStyle(Design.Color.textPrimary)
                        .monospacedDigit()
                    Text(BodyUnits.label(units))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Design.Color.textSecondary)
                }
            }
            if let review = card.review {
                if !review.headline.isEmpty {
                    Text(review.headline)
                        .font(.headline)
                        .foregroundStyle(Design.Color.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(review.observations.prefix(3), id: \.self) { observation in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Circle().fill(Design.Color.honey).frame(width: 4, height: 4)
                        Text(observation)
                            .font(.subheadline)
                            .foregroundStyle(Design.Color.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
