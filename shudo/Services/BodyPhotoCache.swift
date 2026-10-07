import Foundation

/// On-disk cache for physique photos. These are underwear photos, so the
/// cache is deliberately stricter than the meal/profile caches:
/// - Application Support (not Caches), excluded from iCloud/iTunes backup;
/// - every file written with `.completeFileProtection` (unreadable while the
///   device is locked; photos are only shown in the foreground);
/// - keyed by the immutable storage path, so a cached file never goes stale;
/// - cleared on sign-out (`AuthSessionManager.signOut`).
struct BodyPhotoCache: Sendable {
    static let directoryName = "BodyPhotos"
    static let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtection]
    static var directoryAttributes: [FileAttributeKey: Any] { [.protectionKey: FileProtectionType.complete] }

    let root: URL

    /// `Application Support/BodyPhotos`.
    static var shared: BodyPhotoCache? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            .map { BodyPhotoCache(root: $0.appendingPathComponent(directoryName, isDirectory: true)) }
    }

    func fileURL(userId: String, path: String) -> URL? {
        let user = userId.lowercased().filter { $0.isHexDigit || $0 == "-" }
        guard !user.isEmpty,
            path.range(of: #"^[0-9a-z._/-]{1,200}$"#, options: .regularExpression) != nil,
            !path.contains("..")
        else { return nil }
        let name = path.lowercased().replacingOccurrences(of: "/", with: "_")
        return root.appendingPathComponent(user, isDirectory: true).appendingPathComponent(name)
    }

    func load(userId: String, path: String) -> Data? {
        guard let url = fileURL(userId: userId, path: path) else { return nil }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    func save(_ data: Data, userId: String, path: String) throws {
        guard let url = fileURL(userId: userId, path: path) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try prepareDirectory(url.deletingLastPathComponent())
        try data.write(to: url, options: Self.writeOptions)
    }

    func remove(userId: String, path: String) {
        guard let url = fileURL(userId: userId, path: path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: root)
    }

    static func clearAll() {
        shared?.removeAll()
    }

    private func prepareDirectory(_ directory: URL) throws {
        let fileManager = FileManager.default
        for url in [root, directory] where !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(
                at: url, withIntermediateDirectories: true, attributes: Self.directoryAttributes)
        }
        // Excluding the root covers everything under it.
        var root = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
    }
}
