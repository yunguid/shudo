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
}

/// Decides which of today's remaining checkpoints deserve a notification and
/// writes their copy. Pure and deterministic: same context, same plan.
///
/// Principles: at most three pacing nudges a day, none outside 08:00–21:00,
/// every nudge names a number and a concrete food direction, and a checkpoint
/// is dropped entirely when the user is already on track for it — silence is
/// the default, not the exception.
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
                    title: "First log of the day",
                    body: "Nothing logged yet — say breakfast and lunch in one quick voice note."
                ))
            } else if let lastMealAt = context.lastMealAt,
                lunchAt.timeIntervalSince(lastMealAt) > 3 * 60 * 60
            {
                nudges.append(PlannedNudge(
                    id: "lunch",
                    fireAt: lunchAt,
                    title: "Midday check",
                    body: "Lunch logged while it’s fresh is the accurate one — 20 seconds by voice."
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
            let gap = max(0, proteinTarget - context.totals.proteinG)
            nudges.append(PlannedNudge(
                id: "protein",
                fireAt: proteinAt,
                title: "Protein check-in",
                body: "About \(roundedGrams(gap))g of protein to go — grilled chicken, salmon, "
                    + "or skyr covers a lot of it without much of your calorie room."
            ))
        }

        let closeoutAt = checkpoint(closeoutCheckpointMinutes)
        if closeoutAt > context.now, let closeout = closeoutNudge(context, fireAt: closeoutAt) {
            nudges.append(closeout)
        }

        return nudges
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
            let proteinLine = proteinGap >= 20
                ? " Lead with protein — \(roundedGrams(proteinGap))g still to go."
                : ""
            return PlannedNudge(
                id: "closeout",
                fireAt: fireAt,
                title: "Room for a real dinner",
                body: "About \(roundedKcal(remaining)) kcal left today.\(proteinLine)"
            )
        }

        if remaining < -target.caloriesKcal * 0.05 {
            return PlannedNudge(
                id: "closeout",
                fireAt: fireAt,
                title: "Day is full",
                body: "You’re about \(roundedKcal(-remaining)) kcal past target — "
                    + "closing the kitchen now keeps the week easy."
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
        await scheduleWeighInReminder(center, secondsFromMidnight: weighInSecondsFromMidnight)
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
        await scheduleWeighInReminder(center, secondsFromMidnight: weighInSecondsFromMidnight)

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
        secondsFromMidnight: Double
    ) async {
        let bounded = max(0, min(86_399, Int(secondsFromMidnight.rounded())))
        var components = DateComponents()
        components.hour = bounded / 3_600
        components.minute = (bounded % 3_600) / 60

        let content = UNMutableNotificationContent()
        content.title = "Weigh-in"
        content.body = "Say your weight and you’re done."
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
