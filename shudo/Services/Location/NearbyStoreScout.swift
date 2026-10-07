import CoreLocation
import CryptoKit
import Foundation
import MapKit

// Finds stores within walking distance on the device (MapKit, no API keys)
// and produces a `LocationContext` for the coach: locality strings and a
// ranked store list with walking minutes. Coordinates and geohashes stay on
// the phone (SPEC §5.5; location report §1).

// MARK: - Geohash

enum Geohash {
    private static let alphabet = Array("0123456789bcdefghjkmnpqrstuvwxyz")

    static func encode(latitude: Double, longitude: Double, precision: Int = 7) -> String {
        var latRange = (-90.0, 90.0)
        var lonRange = (-180.0, 180.0)
        var hash = ""
        var bit = 0
        var value = 0
        var evenBit = true
        while hash.count < max(1, precision) {
            if evenBit {
                let mid = (lonRange.0 + lonRange.1) / 2
                if longitude >= mid {
                    value = (value << 1) | 1
                    lonRange.0 = mid
                } else {
                    value <<= 1
                    lonRange.1 = mid
                }
            } else {
                let mid = (latRange.0 + latRange.1) / 2
                if latitude >= mid {
                    value = (value << 1) | 1
                    latRange.0 = mid
                } else {
                    value <<= 1
                    latRange.1 = mid
                }
            }
            evenBit.toggle()
            bit += 1
            if bit == 5 {
                hash.append(alphabet[value])
                bit = 0
                value = 0
            }
        }
        return hash
    }
}

// MARK: - Candidates and ranking (pure)

enum NearbyStoreCategory: String, Codable, CaseIterable, Sendable {
    case convenience
    case pharmacy
    case gasStation = "gas_station"
    case grocery
    case cafe
    case bakery
    case restaurant

    /// Ranking bucket with its own cap (≤4 convenience-ish, 3 each other).
    enum Bucket: CaseIterable, Sendable {
        case quickStop, grocery, coffee, restaurant

        var cap: Int { self == .quickStop ? 4 : 3 }
    }

    var bucket: Bucket {
        switch self {
        case .convenience, .pharmacy, .gasStation: return .quickStop
        case .grocery: return .grocery
        case .cafe, .bakery: return .coffee
        case .restaurant: return .restaurant
        }
    }

    init?(poi: MKPointOfInterestCategory?) {
        switch poi {
        case .foodMarket?: self = .grocery
        case .pharmacy?: self = .pharmacy
        case .gasStation?: self = .gasStation
        case .cafe?: self = .cafe
        case .bakery?: self = .bakery
        case .restaurant?: self = .restaurant
        case .store?: self = .convenience
        default: return nil
        }
    }
}

/// A MapKit result reduced to what we rank and cache (on device only).
struct NearbyStoreCandidate: Codable, Equatable, Sendable {
    var placeId: String?
    var name: String
    var category: NearbyStoreCategory
    var latitude: Double
    var longitude: Double
    var addressShort: String?
    /// Straight-line metres from the fix this list was ranked against.
    var distanceMeters: Double

    func distance(from fix: LocationFix) -> Double {
        CLLocation(latitude: latitude, longitude: longitude)
            .distance(from: CLLocation(latitude: fix.latitude, longitude: fix.longitude))
    }
}

enum NearbyStorePolicy {
    static let searchRadius: CLLocationDistance = 800
    static let maximumStores = 12
    static let etaStoreCount = 3
    static let storeListTTL: TimeInterval = 24 * 3600
    static let etaTTL: TimeInterval = 30 * 60
    static let walkingSpeedMetersPerMinute = 80.0
    static let routeDetourFactor = 1.3

    /// `ceil(distance × 1.3 / 80 m/min)`, at least one minute.
    static func estimatedWalkMinutes(distanceMeters: Double) -> Int {
        max(1, Int((max(0, distanceMeters) * routeDetourFactor / walkingSpeedMetersPerMinute).rounded(.up)))
    }

    /// Distances leave the phone rounded to 50 m.
    static func roundedDistance(_ meters: Double) -> Int {
        Int((max(0, meters) / 50).rounded()) * 50
    }

    /// Short stable reference: hash of the place id (or name + rough cell),
    /// so cards can point back at a store without exposing MapKit ids.
    static func ref(for candidate: NearbyStoreCandidate) -> String {
        let basis = candidate.placeId
            ?? "\(candidate.name.lowercased())|\(String(format: "%.3f,%.3f", candidate.latitude, candidate.longitude))"
        let digest = SHA256.hash(data: Data(basis.utf8))
        return "p" + digest.prefix(5).map { String(format: "%02x", $0) }.joined()
    }

    /// Dedupe (place id, else name + ~10 m), nearest first, per-bucket caps,
    /// at most 12.
    static func select(_ candidates: [NearbyStoreCandidate]) -> [NearbyStoreCandidate] {
        var seen = Set<String>()
        var counts: [NearbyStoreCategory.Bucket: Int] = [:]
        var selected: [NearbyStoreCandidate] = []
        let ordered = candidates
            .filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty
                && $0.distanceMeters <= searchRadius * 1.25 }
            .sorted { ($0.distanceMeters, $0.name) < ($1.distanceMeters, $1.name) }
        for candidate in ordered {
            let key = candidate.placeId
                ?? "\(candidate.name.lowercased())|\(String(format: "%.4f,%.4f", candidate.latitude, candidate.longitude))"
            guard seen.insert(key).inserted else { continue }
            let bucket = candidate.category.bucket
            guard counts[bucket, default: 0] < bucket.cap else { continue }
            counts[bucket, default: 0] += 1
            selected.append(candidate)
            if selected.count == maximumStores { break }
        }
        return selected
    }

    /// The nearest stores of distinct chains get a real MapKit ETA.
    static func etaTargets(_ selected: [NearbyStoreCandidate]) -> [NearbyStoreCandidate] {
        var names = Set<String>()
        var targets: [NearbyStoreCandidate] = []
        for candidate in selected.sorted(by: { $0.distanceMeters < $1.distanceMeters }) {
            guard names.insert(candidate.name.lowercased()).inserted else { continue }
            targets.append(candidate)
            if targets.count == etaStoreCount { break }
        }
        return targets
    }

    static func store(
        from candidate: NearbyStoreCandidate,
        etaMinutes: Int?
    ) -> NearbyStore {
        NearbyStore(
            ref: ref(for: candidate),
            name: String(candidate.name.prefix(80)),
            category: candidate.category.rawValue,
            distanceM: roundedDistance(candidate.distanceMeters),
            walkMinutes: etaMinutes ?? estimatedWalkMinutes(distanceMeters: candidate.distanceMeters),
            walkMinutesSource: etaMinutes == nil ? .estimate : .mapkitETA,
            addressShort: candidate.addressShort.map { String($0.prefix(120)) }
        )
    }
}

// MARK: - Cache (geohash-7 cells, 24 h)

struct NearbyStoreCacheEntry: Codable, Equatable, Sendable {
    struct ETA: Codable, Equatable, Sendable {
        var minutes: Int
        var measuredAt: Date
    }

    var geohash: String
    var capturedAt: Date
    var candidates: [NearbyStoreCandidate]
    var locality: LocationContext.Locality?
    /// ref → walking ETA measured from inside this cell.
    var etas: [String: ETA]
}

/// On-device store lists keyed by 7-char geohash (~150 m cell). A file in
/// Application Support with file protection; at most 8 cells kept.
final class NearbyStoreCache: @unchecked Sendable {
    static let maximumCells = 8

    private let lock = NSLock()
    private let url: URL?
    private var entries: [String: NearbyStoreCacheEntry]

    init(fileName: String? = "nearby-stores.json") {
        if let fileName,
           let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            url = base.appendingPathComponent("Coach", isDirectory: true).appendingPathComponent(fileName)
        } else {
            url = nil
        }
        if let url, let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: NearbyStoreCacheEntry].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    func entry(for geohash: String, now: Date) -> NearbyStoreCacheEntry? {
        lock.withLock {
            guard let entry = entries[geohash],
                  now.timeIntervalSince(entry.capturedAt) < NearbyStorePolicy.storeListTTL else { return nil }
            return entry
        }
    }

    func store(_ entry: NearbyStoreCacheEntry) {
        let snapshot: [String: NearbyStoreCacheEntry] = lock.withLock {
            entries[entry.geohash] = entry
            if entries.count > Self.maximumCells {
                let oldest = entries.values.sorted { $0.capturedAt < $1.capturedAt }
                for stale in oldest.prefix(entries.count - Self.maximumCells) {
                    entries[stale.geohash] = nil
                }
            }
            return entries
        }
        guard let url, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func removeAll() {
        lock.withLock { entries = [:] }
        if let url { try? FileManager.default.removeItem(at: url) }
    }
}

// MARK: - Scout

@MainActor
final class NearbyStoreScout {
    static let shared = NearbyStoreScout()

    private let fixProvider: LocationFixProvider
    private let cache: NearbyStoreCache
    private let settingsMirror: CoachSettingsMirror
    private(set) var lastContext: LocationContext?
    private var placeIdsByRef: [String: String] = [:]
    private var inFlight: Task<LocationContext?, Never>?

    init(
        fixProvider: LocationFixProvider? = nil,
        cache: NearbyStoreCache = NearbyStoreCache(),
        settingsMirror: CoachSettingsMirror = CoachSettingsMirror()
    ) {
        self.fixProvider = fixProvider ?? .shared
        self.cache = cache
        self.settingsMirror = settingsMirror
    }

    /// The last context when it is at most `maxAge` old.
    func cachedContext(maxAge: TimeInterval, now: Date = Date()) -> LocationContext? {
        guard let lastContext, lastContext.age(at: now) <= maxAge else { return nil }
        return lastContext
    }

    /// A context only when "Nearby store recs" is on and location is
    /// authorized; refreshes (on-device work, no AI) when stale if allowed.
    func contextIfEnabled(maxAge: TimeInterval, refreshIfStale: Bool) async -> LocationContext? {
        guard settingsMirror.load()?.locationRecsEnabled == true,
              fixProvider.authorization.isAuthorized else { return nil }
        if let cached = cachedContext(maxAge: maxAge) { return cached }
        guard refreshIfStale else { return nil }
        return await refresh()
    }

    /// Forces a new fix + store search ("What should I grab?").
    func refresh() async -> LocationContext? {
        if let inFlight { return await inFlight.value }
        let task = Task { await self.build() }
        inFlight = task
        let context = await task.value
        inFlight = nil
        if let context { lastContext = context }
        return context
    }

    /// The MapKit place id behind a `NearbyStore.ref` (for Directions).
    func mapItemIdentifier(forRef ref: String) -> MKMapItem.Identifier? {
        placeIdsByRef[ref].flatMap(MKMapItem.Identifier.init(rawValue:))
    }

    func clear() {
        lastContext = nil
        placeIdsByRef = [:]
        cache.removeAll()
    }

    private func build() async -> LocationContext? {
        let timeZone = TimeZone.autoupdatingCurrent.identifier
        guard let fix = try? await fixProvider.currentFix() else { return nil }
        let now = Date()
        let cell = Geohash.encode(latitude: fix.latitude, longitude: fix.longitude, precision: 7)
        let cached = cache.entry(for: cell, now: now)
        var locality: LocationContext.Locality
        if let cachedLocality = cached?.locality {
            locality = cachedLocality
        } else {
            locality = await reverseGeocode(fix) ?? LocationContext.Locality(timezone: timeZone)
        }
        locality.timezone = timeZone

        guard fix.isPrecise else {
            // Km-level fix: city only, chain-agnostic picks.
            return LocationContext(capturedAt: now, quality: .approximate, locality: locality, stores: [])
        }

        var candidates: [NearbyStoreCandidate]
        if let cachedCandidates = cached?.candidates {
            candidates = cachedCandidates
        } else {
            candidates = await search(around: fix)
        }
        for index in candidates.indices {
            candidates[index].distanceMeters = candidates[index].distance(from: fix)
        }
        let selected = NearbyStorePolicy.select(candidates)
        var etas = cached?.etas.filter { now.timeIntervalSince($0.value.measuredAt) < NearbyStorePolicy.etaTTL } ?? [:]
        for target in NearbyStorePolicy.etaTargets(selected) {
            let ref = NearbyStorePolicy.ref(for: target)
            guard etas[ref] == nil, let minutes = await walkingETA(to: target) else { continue }
            etas[ref] = NearbyStoreCacheEntry.ETA(minutes: minutes, measuredAt: now)
        }
        cache.store(NearbyStoreCacheEntry(
            geohash: cell,
            capturedAt: cached?.capturedAt ?? now,
            candidates: candidates,
            locality: locality,
            etas: etas
        ))

        var stores: [NearbyStore] = []
        for candidate in selected {
            let ref = NearbyStorePolicy.ref(for: candidate)
            if let placeId = candidate.placeId { placeIdsByRef[ref] = placeId }
            stores.append(NearbyStorePolicy.store(from: candidate, etaMinutes: etas[ref]?.minutes))
        }
        return LocationContext(capturedAt: now, quality: .precise, locality: locality, stores: stores)
    }

    // MARK: MapKit

    private func search(around fix: LocationFix) async -> [NearbyStoreCandidate] {
        async let groceries = pointsOfInterest(around: fix, categories: [.foodMarket, .pharmacy, .gasStation])
        async let food = pointsOfInterest(around: fix, categories: [.cafe, .bakery, .restaurant])
        async let convenience = naturalLanguage("convenience store", around: fix)
        return await groceries + food + convenience
    }

    private func pointsOfInterest(
        around fix: LocationFix,
        categories: [MKPointOfInterestCategory]
    ) async -> [NearbyStoreCandidate] {
        let request = MKLocalPointsOfInterestRequest(
            center: fix.location.coordinate,
            radius: NearbyStorePolicy.searchRadius
        )
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: categories)
        guard let response = try? await MKLocalSearch(request: request).start() else { return [] }
        return response.mapItems.compactMap { candidate(from: $0, fix: fix, fallback: nil) }
    }

    private func naturalLanguage(_ query: String, around fix: LocationFix) async -> [NearbyStoreCandidate] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(
            center: fix.location.coordinate,
            latitudinalMeters: NearbyStorePolicy.searchRadius * 2,
            longitudinalMeters: NearbyStorePolicy.searchRadius * 2
        )
        request.resultTypes = .pointOfInterest
        request.regionPriority = .required
        guard let response = try? await MKLocalSearch(request: request).start() else { return [] }
        return response.mapItems.compactMap { candidate(from: $0, fix: fix, fallback: .convenience) }
    }

    private func candidate(
        from item: MKMapItem,
        fix: LocationFix,
        fallback: NearbyStoreCategory?
    ) -> NearbyStoreCandidate? {
        guard let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
              let category = NearbyStoreCategory(poi: item.pointOfInterestCategory) ?? fallback else {
            return nil
        }
        let location = item.location
        return NearbyStoreCandidate(
            placeId: item.identifier?.rawValue,
            name: name,
            category: category,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            addressShort: item.address?.shortAddress,
            distanceMeters: location.distance(from: fix.location)
        )
    }

    private func walkingETA(to candidate: NearbyStoreCandidate) async -> Int? {
        let request = MKDirections.Request()
        request.source = MKMapItem.forCurrentLocation()
        request.destination = MKMapItem(
            location: CLLocation(latitude: candidate.latitude, longitude: candidate.longitude),
            address: nil
        )
        request.transportType = .walking
        // Throttling (MKError.loadingThrottled) or no route: fall back to the estimate.
        guard let response = try? await MKDirections(request: request).calculateETA() else { return nil }
        return max(1, Int((response.expectedTravelTime / 60).rounded(.up)))
    }

    private func reverseGeocode(_ fix: LocationFix) async -> LocationContext.Locality? {
        guard let request = MKReverseGeocodingRequest(location: fix.location),
              let item = try? await request.mapItems.first,
              let representations = item.addressRepresentations else { return nil }
        let contextual = representations.cityWithContext(.short)
        let region = contextual?
            .split(separator: ",")
            .dropFirst()
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return LocationContext.Locality(
            neighborhood: nil,
            city: representations.cityName,
            region: region.flatMap { $0.isEmpty ? nil : $0 },
            country: representations.region?.identifier,
            timezone: TimeZone.autoupdatingCurrent.identifier
        )
    }
}
