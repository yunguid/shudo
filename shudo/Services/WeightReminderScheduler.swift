import Foundation
import UserNotifications

enum WeightReminderScheduler {
    static let notificationIdentifier = "daily-weight-check-in"
    static let defaultSecondsFromMidnight = 8.0 * 60.0 * 60.0

    static func schedule(enabled: Bool, secondsFromMidnight: Double) async throws {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [notificationIdentifier])
        guard enabled else { return }

        let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        guard granted else {
            throw NSError(
                domain: "WeightReminder",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Notifications are off. Enable them in Settings to use the morning reminder."
                ]
            )
        }

        let bounded = max(0, min(86_399, Int(secondsFromMidnight.rounded())))
        var components = DateComponents()
        components.hour = bounded / 3_600
        components.minute = (bounded % 3_600) / 60

        let content = UNMutableNotificationContent()
        content.title = "Morning check-in"
        content.body = "Log your weight and add an optional mirror or scale photo."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: notificationIdentifier,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        )
        try await center.add(request)
    }
}
