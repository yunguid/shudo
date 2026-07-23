import Foundation

enum ProfileCache {
    private static let keyPrefix = "shudo.profile."

    static func load(userId: String?) -> Profile? {
        guard let key = key(userId: userId),
              let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Profile.self, from: data)
    }

    static func save(_ profile: Profile) {
        guard let key = key(userId: profile.userId),
              let data = try? JSONEncoder().encode(profile) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func clear(userId: String?) {
        guard let key = key(userId: userId) else { return }
        UserDefaults.standard.removeObject(forKey: key)
    }

    static func clearAll() {
        for key in UserDefaults.standard.dictionaryRepresentation().keys
        where key.hasPrefix(keyPrefix) {
            UserDefaults.standard.removeObject(forKey: key)
        }
        ProfilePhotoCache.clearAll()
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

enum ProfilePhotoCache {
    private static let directoryName = "ProfilePhotos"

    static func load(userId: String, expectedPath: String) -> Data? {
        guard metadataPath(userId: userId).flatMap({ try? String(contentsOf: $0, encoding: .utf8) }) == expectedPath,
              let imageURL = imagePath(userId: userId) else { return nil }
        return try? Data(contentsOf: imageURL, options: .mappedIfSafe)
    }

    static func save(_ data: Data, userId: String, path: String) {
        guard let imageURL = imagePath(userId: userId),
              let metadataURL = metadataPath(userId: userId) else { return }
        do {
            try FileManager.default.createDirectory(
                at: imageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: imageURL, options: .atomic)
            try path.write(to: metadataURL, atomically: true, encoding: .utf8)
        } catch {
            clear(userId: userId)
        }
    }

    static func clear(userId: String) {
        for url in [imagePath(userId: userId), metadataPath(userId: userId)].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func clearAll() {
        guard let directory = directory() else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    private static func imagePath(userId: String) -> URL? {
        directory()?.appendingPathComponent("\(safeUserId(userId)).jpg")
    }

    private static func metadataPath(userId: String) -> URL? {
        directory()?.appendingPathComponent("\(safeUserId(userId)).path")
    }

    private static func directory() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    private static func safeUserId(_ userId: String) -> String {
        userId.filter { $0.isHexDigit || $0 == "-" }
    }
}
