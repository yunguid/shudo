import Foundation

/// In-memory cache of signed private-image URLs keyed by storage path.
///
/// Signed URLs previously changed on every list refresh, which made
/// `AsyncImage` treat each refresh as a brand-new resource: thumbnails
/// flashed back to placeholders and every image re-downloaded. Reusing one
/// signed URL for a path until shortly before it expires keeps URL identity
/// stable across refreshes, day switches, and the detail screen, so the
/// system URL cache can serve the bytes without any network work.
///
/// URLs live only in process memory and are dropped on sign-out. Storage
/// paths are immutable per upload (they embed the upload token), so a cached
/// URL can never point at different content.
actor SignedImageURLCache {
    static let shared = SignedImageURLCache()

    /// Lifetime requested when signing. Long enough that a browsing session
    /// reuses one URL; short enough that a leaked URL still expires the
    /// same hour. The margin keeps a URL from being handed out right before
    /// it lapses mid-render.
    static let signedURLLifetime: TimeInterval = 3_600
    static let reuseSafetyMargin: TimeInterval = 300

    struct CachedURL {
        let url: URL
        let reusableUntil: Date
    }

    private var urlsByPath: [String: CachedURL] = [:]
    /// Bumped by `removeAll()` so a fetch that started before sign-out cannot
    /// re-populate the cache with the previous session's URLs afterwards.
    private var epoch = 0

    func currentEpoch() -> Int { epoch }

    func cachedURL(for path: String, now: Date = Date()) -> URL? {
        guard let cached = urlsByPath[path] else { return nil }
        guard now < cached.reusableUntil else {
            urlsByPath[path] = nil
            return nil
        }
        return cached.url
    }

    func store(_ url: URL, for path: String, epoch: Int? = nil, now: Date = Date()) {
        if let epoch, epoch != self.epoch { return }
        urlsByPath[path] = CachedURL(
            url: url,
            reusableUntil: now.addingTimeInterval(
                Self.signedURLLifetime - Self.reuseSafetyMargin
            )
        )
    }

    func removeURL(for path: String) {
        urlsByPath[path] = nil
    }

    func removeAll() {
        urlsByPath.removeAll()
        epoch += 1
    }
}
