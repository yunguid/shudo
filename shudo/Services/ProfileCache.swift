import Foundation

enum ProfileCache {
    private static let keyPrefix = "shudo.profile."

    static func load(userId: String?) -> Profile? {
        guard let key = key(userId: userId),
              let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Profile.self, from: data)
    }

    static func save(_ profile: Profile) {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        UserDefaults.standard.set(data, forKey: keyPrefix + profile.userId)
    }

    static func fallback(userId: String?) -> Profile {
        Profile(
            userId: userId ?? "pending",
            timezone: TimeZone.autoupdatingCurrent.identifier,
            dailyMacroTarget: .defaultDaily
        )
    }

    private static func key(userId: String?) -> String? {
        guard let userId, !userId.isEmpty else { return nil }
        return keyPrefix + userId
    }
}
