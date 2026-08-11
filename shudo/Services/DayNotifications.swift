import Foundation
import UserNotifications

/// One planned local notification for today. Identifiers are stable per
/// checkpoint so a reschedule replaces, never duplicates.
struct PlannedNudge: Equatable, Sendable {
    let id: String
    let fireAt: Date
    let title: String
    let body: String
}

struct NotificationCopy: Equatable, Sendable {
    let title: String
    let body: String
}

/// Everything the nudge planner may consider, captured at scheduling time.
/// Content is computed from the freshest state we have — the plan is rebuilt
/// on every day load, meal change, and foregrounding, so a nudge fired at
/// 15:30 reflects the last thing the user logged, not the morning.
struct DayNudgeContext {
    let now: Date
    let timezone: TimeZone
    let totals: DayTotals
    let target: MacroTarget
    let loggedMealCount: Int
    let lastMealAt: Date?
    let goalType: NutritionGoalType
    let targetWeightKG: Double?
    let units: String
    let weightCheckIns: [WeightCheckIn]
    let recentNutrition: [DailyNutritionTotal]
    let targetHistory: [DailyMacroTargetSnapshot]
    let micronutrientReport: WeeklyMicronutrientReport?
    let micronutrientReportWeekEnd: Date?
}

/// Connects a stable weight trend to intake over the same period. It avoids
/// interpreting one noisy weigh-in and falls back to a plain reminder until
/// both weight and meal coverage are useful.
enum WeightReminderPolicy {
    static func copy(context: DayNudgeContext) -> NotificationCopy {
        let fallback = NotificationCopy(title: "Weigh-in", body: "Say your weight and you’re done.")
        let allWeights = context.weightCheckIns.sorted { $0.localDay < $1.localDay }
        guard let latestDay = allWeights.last?.localDay else { return fallback }
        let cutoffDay = day(latestDay, adding: -27) ?? latestDay
        let ordered = allWeights.filter { $0.localDay >= cutoffDay }
        guard ordered.count >= 4,
            let firstDay = ordered.first?.localDay,
            let lastDay = ordered.last?.localDay,
            daysBetween(firstDay, lastDay) >= 7
        else { return fallback }

        let leading = ordered.prefix(min(3, ordered.count / 2))
        let trailing = ordered.suffix(min(3, ordered.count / 2))
        let start = leading.map(\.weightKG).reduce(0, +) / Double(leading.count)
        let end = trailing.map(\.weightKG).reduce(0, +) / Double(trailing.count)
        let change = end - start

        let matchingNutrition = context.recentNutrition.filter {
            $0.localDay >= firstDay && $0.localDay <= lastDay && $0.entryCount > 0
        }
        guard matchingNutrition.count >= 5 else {
            return NotificationCopy(
                title: "Weigh-in",
                body: "Keep the weight trend useful—say today’s weight and you’re done."
            )
        }
        let calorieDelta = matchingNutrition.reduce(0.0) { result, day in
            let target = NutritionProgressPolicy.effectiveTarget(
                on: day.localDay,
                history: context.targetHistory,
                fallback: context.target
            )
            return result + day.caloriesKcal - target.caloriesKcal
        } / Double(matchingNutrition.count)

        let weightChange = formattedWeight(abs(change), units: context.units)
        let direction = change <= -0.15 ? "down" : change >= 0.15 ? "up" : "steady"
        let alignment: String
        switch (context.goalType, direction) {
        case (.lose, "down"), (.gain, "up"), (.maintain, "steady"):
            alignment = "toward your goal"
        case (.maintain, _):
            alignment = "against a maintain goal"
        default:
            alignment = "away from your goal"
        }
        let trendText = direction == "steady"
            ? "Your smoothed trend is steady \(alignment)"
            : "Your smoothed trend is \(direction) \(weightChange) \(alignment)"
        let intakeText: String
        if abs(calorieDelta) < 50 {
            intakeText = "logged intake averaged near target"
        } else {
            let relation = calorieDelta < 0 ? "below" : "above"
            intakeText = "logged intake averaged \(roundedKcal(abs(calorieDelta))) kcal \(relation) target"
        }
        let goalText: String
        if let targetWeight = context.targetWeightKG {
            goalText = ", \(formattedWeight(abs(end - targetWeight), units: context.units)) from target"
        } else {
            goalText = ""
        }
        return NotificationCopy(
            title: "Weigh-in",
            body: "\(trendText)\(goalText); \(intakeText). Add today’s reading."
        )
    }

    private static func daysBetween(_ first: String, _ last: String) -> Int {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        guard let start = formatter.date(from: first), let end = formatter.date(from: last) else {
            return 0
        }
        return Calendar(identifier: .gregorian).dateComponents([.day], from: start, to: end).day ?? 0
    }

    private static func day(_ localDay: String, adding offset: Int) -> String? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: localDay),
            let shifted = formatter.calendar.date(byAdding: .day, value: offset, to: date)
        else { return nil }
        return formatter.string(from: shifted)
    }

    private static func formattedWeight(_ kilograms: Double, units: String) -> String {
        let value = WeightCheckInPolicy.displayedValue(kilograms: kilograms, units: units)
        return String(format: "%.1f %@", value, units.lowercased() == "imperial" ? "lb" : "kg")
    }

    private static func roundedKcal(_ value: Double) -> Int {
        max(0, Int((value / 10).rounded()) * 10)
    }
}

/// Decides which of today's remaining checkpoints deserve a notification and
/// writes their copy. Pure and deterministic: same context, same plan.
///
/// At each checkpoint the policy chooses the most relevant action supported
/// by current macros, goal direction, and recent high-confidence micronutrient
/// history. Silence wins when the day is already handling itself.
enum DayNudgePolicy {
    static let lunchCheckpointMinutes = 12 * 60 + 45
    static let proteinCheckpointMinutes = 15 * 60 + 30
    static let closeoutCheckpointMinutes = 20 * 60 + 30
    /// A meal logged within this window before a checkpoint proves the user
    /// is engaged; the checkpoint stays quiet.
    static let recentMealQuietWindow: TimeInterval = 60 * 60

    static func plannedNudges(context: DayNudgeContext) -> [PlannedNudge] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = context.timezone
        let dayStart = calendar.startOfDay(for: context.now)
        func checkpoint(_ minutes: Int) -> Date {
            dayStart.addingTimeInterval(TimeInterval(minutes * 60))
        }

        var nudges: [PlannedNudge] = []

        let lunchAt = checkpoint(lunchCheckpointMinutes)
        if lunchAt > context.now, !mealLoggedRecently(context, before: lunchAt) {
            if context.loggedMealCount == 0 {
                nudges.append(PlannedNudge(
                    id: "lunch",
                    fireAt: lunchAt,
                    title: "Make today measurable",
                    body: "Nothing is logged yet—say breakfast and lunch in one quick voice note."
                ))
            } else if let lastMealAt = context.lastMealAt,
                lunchAt.timeIntervalSince(lastMealAt) > 3 * 60 * 60
            {
                nudges.append(PlannedNudge(
                    id: "lunch",
                    fireAt: lunchAt,
                    title: "Keep the trend accurate",
                    body: "Lunch logged while it’s fresh makes the weight-and-intake trend more useful."
                ))
            }
        }

        let proteinAt = checkpoint(proteinCheckpointMinutes)
        let proteinTarget = context.target.proteinG
        if proteinAt > context.now,
            proteinTarget > 0,
            context.totals.proteinG < proteinTarget * 0.45,
            !mealLoggedRecently(context, before: proteinAt)
        {
            nudges.append(middayNutritionNudge(context, fireAt: proteinAt))
        }

        let closeoutAt = checkpoint(closeoutCheckpointMinutes)
        if closeoutAt > context.now, let closeout = closeoutNudge(context, fireAt: closeoutAt) {
            nudges.append(closeout)
        }

        return nudges
    }

    private static func middayNutritionNudge(
        _ context: DayNudgeContext,
        fireAt: Date
    ) -> PlannedNudge {
        let gap = max(0, context.target.proteinG - context.totals.proteinG)
        if let nutrient = priorityMicronutrient(context),
            let food = foodDirection(for: nutrient.id)
        {
            return PlannedNudge(
                id: "nutrition",
                fireAt: fireAt,
                title: "Close two gaps",
                body: "About \(roundedGrams(gap))g protein remains. Recent logs ran low in "
                    + "\(nutrient.name.lowercased()); \(food) helps with both."
            )
        }
        let proteinFood = context.goalType == .gain
            ? "chicken with rice, salmon, or Greek yogurt with granola"
            : "grilled chicken, salmon, or skyr"
        return PlannedNudge(
            id: "nutrition",
            fireAt: fireAt,
            title: "Protein is the next lever",
            body: "About \(roundedGrams(gap))g protein remains—\(proteinFood) can close it."
        )
    }

    private static func closeoutNudge(
        _ context: DayNudgeContext,
        fireAt: Date
    ) -> PlannedNudge? {
        let target = context.target
        guard target.caloriesKcal > 0 else { return nil }
        let remaining = target.caloriesKcal - context.totals.caloriesKcal

        // 400 kcal at 8:30pm is a real dinner-sized gap even when it's under
        // a quarter of a large target (Luke hit exactly this: ~600 left of
        // 2,461 and the percentage rule alone would have stayed silent).
        if remaining >= min(target.caloriesKcal * 0.25, 400) {
            let proteinGap = max(0, target.proteinG - context.totals.proteinG)
            if let nutrient = priorityMicronutrient(context),
                let food = foodDirection(for: nutrient.id)
            {
                return PlannedNudge(
                    id: "closeout",
                    fireAt: fireAt,
                    title: "Use the room well",
                    body: "About \(roundedKcal(remaining)) kcal remains. Recent logs ran low in "
                        + "\(nutrient.name.lowercased()); \(food) is a useful direction."
                )
            }
            let carbGap = max(0, target.carbsG - context.totals.carbsG)
            let fatGap = max(0, target.fatG - context.totals.fatG)
            if proteinGap < 20, carbGap >= 30 {
                return PlannedNudge(
                    id: "closeout",
                    fireAt: fireAt,
                    title: "Carbs are the open lane",
                    body: "About \(roundedKcal(remaining)) kcal and \(roundedGrams(carbGap))g carbs remain—"
                        + "rice, potatoes, oats, or fruit fit the day."
                )
            }
            if proteinGap < 20, carbGap < 30, fatGap >= 10, context.goalType == .gain {
                return PlannedNudge(
                    id: "closeout",
                    fireAt: fireAt,
                    title: "Add energy efficiently",
                    body: "Protein and carbs are close. Nuts, avocado, or olive oil can use "
                        + "the remaining \(roundedKcal(remaining)) kcal."
                )
            }
            let proteinLine = proteinGap >= 20
                ? " Lead with \(roundedGrams(proteinGap))g of remaining protein."
                : ""
            let title = context.goalType == .gain ? "Stay on pace to gain" : "Room for a real meal"
            return PlannedNudge(
                id: "closeout",
                fireAt: fireAt,
                title: title,
                body: "About \(roundedKcal(remaining)) kcal left today.\(proteinLine)"
            )
        }

        if remaining < -target.caloriesKcal * 0.05 {
            return PlannedNudge(
                id: "closeout",
                fireAt: fireAt,
                title: context.goalType == .gain ? "Target reached" : "Day is full",
                body: "You’re about \(roundedKcal(-remaining)) kcal past target — "
                    + (context.goalType == .gain
                        ? "no extra catch-up meal is needed."
                        : "closing the kitchen now supports your weekly pace.")
            )
        }

        if target.fatG > 0, context.totals.fatG > target.fatG,
            context.totals.caloriesKcal < target.caloriesKcal
        {
            return PlannedNudge(
                id: "closeout",
                fireAt: fireAt,
                title: "Go lean tonight",
                body: "Fat reached its target early — white fish, shrimp, or egg whites "
                    + "fill the remaining \(roundedKcal(remaining)) kcal without adding more."
            )
        }

        // Close to target with meals logged: the day handled itself.
        return nil
    }

    private static func priorityMicronutrient(
        _ context: DayNudgeContext
    ) -> WeeklyMicronutrient? {
        guard let report = context.micronutrientReport,
            report.daysLogged >= 4,
            let reportEnd = context.micronutrientReportWeekEnd,
            context.now.timeIntervalSince(reportEnd) >= 0,
            context.now.timeIntervalSince(reportEnd) <= 21 * 24 * 60 * 60
        else { return nil }
        return report.nutrients
            .filter { $0.status == "low" && $0.confidence != "low" }
            .sorted { $0.percentReference < $1.percentReference }
            .first { foodDirection(for: $0.id) != nil }
    }

    private static func foodDirection(for nutrientID: String) -> String? {
        switch nutrientID {
        case "fiber": return "beans, lentils, berries, or vegetables"
        case "iron": return "lean beef, lentils, or spinach with peppers"
        case "calcium": return "Greek yogurt, skyr, or calcium-set tofu"
        case "potassium": return "potatoes, beans, yogurt, or bananas"
        case "magnesium": return "pumpkin seeds, beans, or leafy greens"
        case "vitamin_c": return "peppers, citrus, or berries"
        case "vitamin_d": return "salmon, eggs, or fortified yogurt"
        case "vitamin_b12": return "salmon, lean beef, eggs, or fortified foods"
        case "folate": return "lentils, beans, or leafy greens"
        case "omega_3": return "salmon, sardines, chia, or walnuts"
        case "zinc": return "lean beef, shellfish, or pumpkin seeds"
        default: return nil
        }
    }

    private static func mealLoggedRecently(_ context: DayNudgeContext, before fireAt: Date) -> Bool {
        guard let lastMealAt = context.lastMealAt else { return false }
        return fireAt.timeIntervalSince(lastMealAt) < recentMealQuietWindow
    }

    private static func roundedKcal(_ value: Double) -> Int {
        max(0, Int((value / 10).rounded()) * 10)
    }

    private static func roundedGrams(_ value: Double) -> Int {
        max(0, Int((value / 5).rounded()) * 5)
    }
}

/// Owns every local notification the app schedules: the repeating morning
/// weigh-in reminder and today's dynamic pacing nudges, behind one master
/// toggle. Replaces the old WeightReminderScheduler.
enum DayNotificationScheduler {
    static let enabledDefaultsKey = "dayNotificationsEnabled"
    static let weighInSecondsDefaultsKey = "weightReminderSecondsFromMidnight"
    static let legacyEnabledDefaultsKey = "weightReminderEnabled"
    static let defaultWeighInSecondsFromMidnight = 8.0 * 60.0 * 60.0

    static let weighInIdentifier = "shudo.nudge.weighin"
    static let nudgeIdentifierPrefix = "shudo.nudge."
    private static let legacyIdentifiers = ["daily-weight-check-in"]

    /// The old settings toggle only covered the weigh-in reminder; carry an
    /// existing opt-in over to the combined toggle exactly once.
    static func migrateLegacyPreference(defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: enabledDefaultsKey) == nil,
            defaults.bool(forKey: legacyEnabledDefaultsKey)
        else { return }
        defaults.set(true, forKey: enabledDefaultsKey)
    }

    /// Master-toggle flip. Throwing here means authorization was declined;
    /// the caller resets its toggle and shows the message.
    static func applyEnabled(
        _ enabled: Bool,
        weighInSecondsFromMidnight: Double
    ) async throws {
        let center = UNUserNotificationCenter.current()
        guard enabled else {
            await removeAllOwnedNotifications(center)
            return
        }
        let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        guard granted else {
            throw NSError(
                domain: "DayNotifications",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Notifications are off. Enable them in Settings to use reminders."
                ]
            )
        }
        await scheduleWeighInReminder(
            center,
            secondsFromMidnight: weighInSecondsFromMidnight,
            copy: NotificationCopy(title: "Weigh-in", body: "Say your weight and you’re done.")
        )
    }

    /// Rebuilds today's plan from live data. Cheap and idempotent — call it
    /// whenever today's meals change or the app comes to the foreground.
    static func reschedule(
        context: DayNudgeContext,
        weighInSecondsFromMidnight: Double,
        defaults: UserDefaults = .standard
    ) async {
        let center = UNUserNotificationCenter.current()
        guard defaults.bool(forKey: enabledDefaultsKey) else { return }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
        else { return }

        await removePendingNudges(center)
        await scheduleWeighInReminder(
            center,
            secondsFromMidnight: weighInSecondsFromMidnight,
            copy: WeightReminderPolicy.copy(context: context)
        )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = context.timezone
        for nudge in DayNudgePolicy.plannedNudges(context: context) {
            let content = UNMutableNotificationContent()
            content.title = nudge.title
            content.body = nudge.body
            content.sound = .default
            let components = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: nudge.fireAt
            )
            let request = UNNotificationRequest(
                identifier: nudgeIdentifierPrefix + nudge.id,
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            )
            try? await center.add(request)
        }
    }

    private static func scheduleWeighInReminder(
        _ center: UNUserNotificationCenter,
        secondsFromMidnight: Double,
        copy: NotificationCopy
    ) async {
        let bounded = max(0, min(86_399, Int(secondsFromMidnight.rounded())))
        var components = DateComponents()
        components.hour = bounded / 3_600
        components.minute = (bounded % 3_600) / 60

        let content = UNMutableNotificationContent()
        content.title = copy.title
        content.body = copy.body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: weighInIdentifier,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        )
        center.removePendingNotificationRequests(withIdentifiers: legacyIdentifiers)
        try? await center.add(request)
    }

    private static func removePendingNudges(_ center: UNUserNotificationCenter) async {
        let pending = await center.pendingNotificationRequests()
        let owned = pending.map(\.identifier).filter {
            $0.hasPrefix(nudgeIdentifierPrefix) && $0 != weighInIdentifier
        }
        center.removePendingNotificationRequests(withIdentifiers: owned + legacyIdentifiers)
    }

    private static func removeAllOwnedNotifications(_ center: UNUserNotificationCenter) async {
        let pending = await center.pendingNotificationRequests()
        let owned = pending.map(\.identifier).filter { $0.hasPrefix(nudgeIdentifierPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: owned + legacyIdentifiers)
    }
}
