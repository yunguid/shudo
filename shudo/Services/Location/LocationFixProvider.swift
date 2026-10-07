import CoreLocation
import Foundation

/// One location reading. Stays on the device: only `LocationContext`
/// (locality strings + store list) is ever sent anywhere.
struct LocationFix: Equatable, Sendable {
    var latitude: Double
    var longitude: Double
    var horizontalAccuracy: Double
    var timestamp: Date
    /// False when Precise Location is off (kilometre-level readings).
    var isPrecise: Bool

    var location: CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: 0,
            horizontalAccuracy: horizontalAccuracy,
            verticalAccuracy: -1,
            timestamp: timestamp
        )
    }
}

enum LocationAuthorization: Equatable, Sendable {
    case notDetermined
    case denied
    case restricted
    case whenInUse
    case always

    init(_ status: CLAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .denied: self = .denied
        case .restricted: self = .restricted
        case .authorizedWhenInUse: self = .whenInUse
        case .authorizedAlways: self = .always
        @unknown default: self = .denied
        }
    }

    var isAuthorized: Bool { self == .whenInUse || self == .always }

    /// The value `coach_sync` reports in `device.location_status`.
    var syncStatus: CoachSyncRequest.LocationStatus {
        switch self {
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        case .whenInUse, .always: return .whenInUse
        }
    }
}

enum LocationFixError: Error, Equatable {
    case notAuthorized
    case unavailable
    case timedOut
}

/// When a live update is good enough to use (SPEC §5.5: ≤100 m, <2 min old;
/// with Precise Location off, any km-level reading counts as approximate).
enum LocationFixPolicy {
    static let maximumPreciseAccuracy: CLLocationAccuracy = 100
    static let maximumApproximateAccuracy: CLLocationAccuracy = 5_000
    static let maximumAge: TimeInterval = 120
    static let timeout: TimeInterval = 8

    static func accepts(accuracy: CLLocationAccuracy, age: TimeInterval, accuracyLimited: Bool) -> Bool {
        guard accuracy >= 0, age < maximumAge, age > -30 else { return false }
        return accuracy <= (accuracyLimited ? maximumApproximateAccuracy : maximumPreciseAccuracy)
    }

    static func quality(accuracy: CLLocationAccuracy, accuracyLimited: Bool) -> LocationContext.Quality {
        accuracyLimited || accuracy > maximumPreciseAccuracy ? .approximate : .precise
    }
}

/// When-In-Use location fixes via `CLServiceSession` + `CLLocationUpdate`.
@MainActor
final class LocationFixProvider: NSObject, CLLocationManagerDelegate {
    static let shared = LocationFixProvider()
    /// Key in `NSLocationTemporaryUsageDescriptionDictionary`.
    static let fullAccuracyPurposeKey = "NearbyGrab"

    private let manager = CLLocationManager()
    private var authorizationWaiters: [CheckedContinuation<LocationAuthorization, Never>] = []

    override init() {
        super.init()
        manager.delegate = self
    }

    var authorization: LocationAuthorization { LocationAuthorization(manager.authorizationStatus) }
    var isPreciseLocationEnabled: Bool { manager.accuracyAuthorization == .fullAccuracy }

    /// Prompts once for When-In-Use; returns the resulting status.
    func requestWhenInUseAuthorization() async -> LocationAuthorization {
        guard authorization == .notDetermined else { return authorization }
        return await withCheckedContinuation { continuation in
            authorizationWaiters.append(continuation)
            manager.requestWhenInUseAuthorization()
        }
    }

    /// Asks for one-time precise location (for real walking times).
    func requestTemporaryFullAccuracy() async -> Bool {
        guard authorization.isAuthorized else { return false }
        if isPreciseLocationEnabled { return true }
        do {
            try await manager.requestTemporaryFullAccuracyAuthorization(
                withPurposeKey: Self.fullAccuracyPurposeKey
            )
        } catch {
            return false
        }
        return isPreciseLocationEnabled
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.resumeAuthorizationWaiters() }
    }

    private func resumeAuthorizationWaiters() {
        let status = authorization
        guard status != .notDetermined, !authorizationWaiters.isEmpty else { return }
        let waiters = authorizationWaiters
        authorizationWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: status) }
    }

    /// The first acceptable fix within `timeout` seconds.
    func currentFix(timeout: TimeInterval = LocationFixPolicy.timeout) async throws -> LocationFix {
        guard authorization.isAuthorized else { throw LocationFixError.notAuthorized }
        let session = CLServiceSession(
            authorization: .whenInUse,
            fullAccuracyPurposeKey: Self.fullAccuracyPurposeKey
        )
        defer { session.invalidate() }
        return try await withThrowingTaskGroup(of: LocationFix.self) { group in
            group.addTask { try await Self.firstAcceptableFix() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(1, timeout) * 1_000_000_000))
                throw LocationFixError.timedOut
            }
            defer { group.cancelAll() }
            guard let fix = try await group.next() else { throw LocationFixError.unavailable }
            return fix
        }
    }

    nonisolated private static func firstAcceptableFix() async throws -> LocationFix {
        for try await update in CLLocationUpdate.liveUpdates() {
            if update.authorizationDenied || update.authorizationDeniedGlobally
                || update.authorizationRestricted {
                throw LocationFixError.notAuthorized
            }
            guard let location = update.location else { continue }
            let age = -location.timestamp.timeIntervalSinceNow
            guard LocationFixPolicy.accepts(
                accuracy: location.horizontalAccuracy,
                age: age,
                accuracyLimited: update.accuracyLimited
            ) else { continue }
            return LocationFix(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                horizontalAccuracy: location.horizontalAccuracy,
                timestamp: location.timestamp,
                isPrecise: LocationFixPolicy.quality(
                    accuracy: location.horizontalAccuracy,
                    accuracyLimited: update.accuracyLimited
                ) == .precise
            )
        }
        throw LocationFixError.unavailable
    }
}
