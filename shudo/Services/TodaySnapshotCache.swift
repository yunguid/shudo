import Foundation

/// The last server-confirmed picture of "today", persisted so a cold launch
/// renders the meal list in the first frame and refreshes silently, instead
/// of opening on a skeleton. One snapshot per user; ignored when its
/// localDay no longer matches the current day in the profile's timezone.
enum TodaySnapshotCache {
    struct Snapshot: Codable {
        let localDay: String
        let entries: [Entry]
    }

    private static let keyPrefix = "shudo.todaySnapshot."

    static func load(userId: String, expectedLocalDay: String) -> [Entry]? {
        guard let key = key(userId: userId),
              let data = UserDefaults.standard.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.localDay == expectedLocalDay else { return nil }
        return snapshot.entries
    }

    static func save(_ entries: [Entry], userId: String, localDay: String) {
        guard let key = key(userId: userId),
              let data = try? JSONEncoder().encode(
                Snapshot(localDay: localDay, entries: entries)
              ) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func clearAll() {
        for key in UserDefaults.standard.dictionaryRepresentation().keys
        where key.hasPrefix(keyPrefix) {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private static func key(userId: String) -> String? {
        guard !userId.isEmpty else { return nil }
        return keyPrefix + userId
    }
}
