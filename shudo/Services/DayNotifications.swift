import Foundation
import UserNotifications

/// One planned local notification for today. Identifiers are stable per
/// checkpoint so a reschedule replaces, never duplicates. Like the coach's
/// texts, every nudge is sent by "Shudo"; the body says what it's about.
struct PlannedNudge: Equatable, Sendable {
    let id: String
    let fireAt: Date
    let body: String
}

struct NotificationCopy: Equatable, Sendable {
    let body: String
}

/// Everything the nudge planner may consider, captured at scheduling time.
/// Content is computed from the freshest state we have — the plan is rebuilt
/// on every day load, meal change, and foregrounding. Local notifications
/// cannot fetch at delivery time, so their copy explicitly describes a snapshot.
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
    /// Not used in copy (a text from Shudo doesn't open with his name);
    /// kept so callers stay source-compatible.
    var displayName: String? = nil
}

/// Connects a stable weight trend to intake over the same period. It avoids
/// interpreting one noisy weigh-in and falls back to a plain reminder until
/// both weight and meal coverage are useful.
enum WeightReminderPolicy {
    static let plainBody = "Weigh-in time. Say the number and you’re done."

    static func copy(context: DayNudgeContext) -> NotificationCopy {
        let fallback = NotificationCopy(body: WeightReminderPolicy.plainBody)
        let allWeights = context.weightCheckIns.filter { $0.weightKG != nil }.sorted { $0.localDay < $1.localDay }
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
        let start = leading.compactMap(\.weightKG).reduce(0, +) / Double(leading.count)
        let end = trailing.compactMap(\.weightKG).reduce(0, +) / Double(trailing.count)
        let change = end - start

        let matchingNutrition = context.recentNutrition.filter {
            $0.localDay >= firstDay && $0.localDay <= lastDay && $0.entryCount > 0
        }
        guard matchingNutrition.count >= 5 else {
            return NotificationCopy(body: "Weigh-in time. One number keeps the trend honest.")
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
            ? "Trend: steady, \(alignment)"
            : "Trend: \(direction) \(weightChange), \(alignment)"
        let intakeText: String
        if abs(calorieDelta) < 50 {
            intakeText = "Logged intake ran near target."
        } else {
            let relation = calorieDelta < 0 ? "under" : "over"
            intakeText = "Logged intake ran \(roundedKcal(abs(calorieDelta))) kcal \(relation) target."
        }
        let goalText: String
        if let targetWeight = context.targetWeightKG {
            goalText = ", \(formattedWeight(abs(end - targetWeight), units: context.units)) from target"
        } else {
            goalText = ""
        }
        return NotificationCopy(body: "\(trendText)\(goalText). \(intakeText) Today’s weight?")
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
/// Copy describes the last logged snapshot ("as of your last log"), not
/// assumed complete intake, and reads like a short text: one fact, one
/// question. Silence wins for empty-day nutrition gaps and recent meals.
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
            calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: dayStart)!
        }

        var nudges: [PlannedNudge] = []

        let lunchAt = checkpoint(lunchCheckpointMinutes)
        if lunchAt > context.now, !mealLoggedRecently(context, before: lunchAt) {
            if context.loggedMealCount == 0 {
                nudges.append(PlannedNudge(
                    id: "lunch",
                    fireAt: lunchAt,
                    body: "Nothing logged yet today. Add what you’ve eaten when you can."
                ))
            } else if let lastMealAt = context.lastMealAt,
                lunchAt.timeIntervalSince(lastMealAt) > 3 * 60 * 60
            {
                nudges.append(PlannedNudge(
                    id: "lunch",
                    fireAt: lunchAt,
                    body: "Log lunch while it’s fresh."
                ))
            }
        }

        let proteinAt = checkpoint(proteinCheckpointMinutes)
        let proteinTarget = context.target.proteinG
        if proteinAt > context.now,
            proteinTarget > 0,
            context.loggedMealCount > 0,
            context.totals.proteinG < proteinTarget * 0.45,
            !mealLoggedRecently(context, before: proteinAt)
        {
            nudges.append(middayNutritionNudge(context, fireAt: proteinAt))
        }

        let closeoutAt = checkpoint(closeoutCheckpointMinutes)
        if closeoutAt > context.now, !mealLoggedRecently(context, before: closeoutAt), let closeout = closeoutNudge(context, fireAt: closeoutAt) {
            nudges.append(closeout)
        }

        return Array(nudges.suffix(2))
    }

    private static func middayNutritionNudge(
        _ context: DayNudgeContext,
        fireAt: Date
    ) -> PlannedNudge {
        let logged = max(0, Int(context.totals.proteinG.rounded()))
        let target = max(0, Int(context.target.proteinG.rounded()))
        let gap = max(0, target - logged)
        return PlannedNudge(
            id: "nutrition",
            fireAt: fireAt,
            body: "As of your last log: \(logged)g protein, \(gap)g to \(target)g. Anything unlogged?"
        )
    }

    private static func closeoutNudge(
        _ context: DayNudgeContext,
        fireAt: Date
    ) -> PlannedNudge? {
        let target = context.target
        guard target.caloriesKcal > 0, context.loggedMealCount > 0 else { return nil }
        let remaining = target.caloriesKcal - context.totals.caloriesKcal

        // A log is not proof of complete intake. Offer a log check, never
        // instructions to eat or stop eating based on an assumed deficit.
        if remaining >= min(target.caloriesKcal * 0.25, 400) {
            return PlannedNudge(
                id: "closeout",
                fireAt: fireAt,
                body: "As of your last log: \(roundedKcal(context.totals.caloriesKcal).formatted()) kcal, about \(roundedKcal(remaining).formatted()) under target. Anything still to log?"
            )
        }
        return nil
    }

    private static func mealLoggedRecently(_ context: DayNudgeContext, before fireAt: Date) -> Bool {
        guard let lastMealAt = context.lastMealAt else { return false }
        return fireAt.timeIntervalSince(lastMealAt) < recentMealQuietWindow
    }

    private static func roundedKcal(_ value: Double) -> Int {
        max(0, Int((value / 10).rounded()) * 10)
    }
}

/// Owns the app's non-coach local notifications: the repeating morning
/// weigh-in reminder and today's pacing nudges, behind one master toggle.
/// With the coach enabled, the server-written coach queue owns the day
/// (`CoachSync`), so `DayNudgePolicy` only runs as the offline fallback while
/// the coach is disabled.
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
        let granted = await CoachNotificationAuthorization.request()
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
            copy: NotificationCopy(body: WeightReminderPolicy.plainBody)
        )
    }

    /// Pacing nudges are a fallback for when no coach queue exists: they stay
    /// off while the coach is enabled so Luke never gets both voices.
    static func shouldScheduleFallbackNudges(defaults: UserDefaults = .standard) -> Bool {
        !CoachSettingsMirror.isCoachEnabled(defaults: defaults)
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
        guard shouldScheduleFallbackNudges(defaults: defaults) else { return }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = context.timezone
        for nudge in DayNudgePolicy.plannedNudges(context: context) {
            let content = textContent(body: nudge.body)
            var components = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: nudge.fireAt
            )
            components.timeZone = context.timezone
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

        let content = textContent(body: copy.body)

        let request = UNNotificationRequest(
            identifier: weighInIdentifier,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        )
        center.removePendingNotificationRequests(withIdentifiers: legacyIdentifiers)
        try? await center.add(request)
    }

    /// The coach texts' look: from "Shudo", in Shudo's thread, soft chime.
    static func textContent(body: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = CoachNotificationIdentifiers.title
        content.body = body
        content.threadIdentifier = CoachNotificationIdentifiers.threadIdentifier
        content.sound = UNNotificationSound(named: UNNotificationSoundName(CoachNotificationIdentifiers.soundName))
        content.interruptionLevel = .active
        return content
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
