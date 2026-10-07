import Foundation
import Testing
import UserNotifications
@testable import shudo

struct CoachRoutingTests {
    private let messageId = UUID(uuidString: "0B6A1D6E-0000-4000-8000-00000000000A")!

    // MARK: Deep links

    @Test func buildsLowercaseCoachLinks() {
        let url = AppRouter.coachDeepLink(messageId: messageId, localDay: "2026-10-06")
        #expect(url.absoluteString == "shudo://coach?message=0b6a1d6e-0000-4000-8000-00000000000a&day=2026-10-06")
        let noDay = AppRouter.coachDeepLink(messageId: messageId, localDay: nil)
        #expect(noDay.absoluteString == "shudo://coach?message=0b6a1d6e-0000-4000-8000-00000000000a")
        let badDay = AppRouter.coachDeepLink(messageId: messageId, localDay: "yesterday")
        #expect(!badDay.absoluteString.contains("day="))
    }

    @Test func parsesCoachLinks() throws {
        func destination(_ string: String) throws -> AppRouter.CoachRequest.Destination? {
            AppRouter.coachDestination(for: try #require(URL(string: string)))
        }
        #expect(try destination("shudo://coach?message=0b6a1d6e-0000-4000-8000-00000000000a&day=2026-10-06")
            == .thread(messageId: messageId, localDay: "2026-10-06"))
        #expect(try destination("SHUDO://Coach?message=0B6A1D6E-0000-4000-8000-00000000000A")
            == .thread(messageId: messageId, localDay: nil))
        #expect(try destination("shudo://coach") == .thread(messageId: nil, localDay: nil))
        #expect(try destination("shudo://coach?message=not-a-uuid&day=2026-02-30")
            == .thread(messageId: nil, localDay: nil), "bad values are dropped, the link still opens")
        #expect(try destination("shudo:///coach?day=2026-10-05") == .thread(messageId: nil, localDay: "2026-10-05"))
        #expect(try destination("shudo://coach/settings") == .settings)
        #expect(try destination("shudo://capture") == nil)
        #expect(try destination("https://coach?message=0b6a1d6e-0000-4000-8000-00000000000a") == nil)
    }

    @Test @MainActor func routerPublishesAConsumableCoachRequest() throws {
        let router = AppRouter.shared
        let link = AppRouter.coachDeepLink(messageId: messageId, localDay: "2026-10-06")
        router.handle(url: link)
        let request = try #require(router.coachRequest)
        #expect(request.destination == .thread(messageId: messageId, localDay: "2026-10-06"))

        // A stale request object can't clear a newer one.
        router.handle(url: AppRouter.coachSettingsURL)
        let settings = try #require(router.coachRequest)
        router.consume(request)
        #expect(router.coachRequest == settings)
        #expect(settings.destination == .settings)
        router.consume(settings)
        #expect(router.coachRequest == nil)

        // Other routes are untouched.
        router.handle(url: try #require(URL(string: "shudo://capture")))
        #expect(router.coachRequest == nil)
        if let capture = router.captureRequest { router.consume(capture) }
    }

    // MARK: Notification actions

    private func action(
        _ identifier: String,
        reply: String? = nil,
        payload: CoachNotificationPayload? = nil,
        notification: String? = nil
    ) -> CoachNotificationAction {
        CoachNotificationAction(
            actionIdentifier: identifier,
            notificationIdentifier: notification ?? CoachNotificationIdentifiers.message(messageId),
            payload: payload,
            replyText: reply
        )
    }

    private var payload: CoachNotificationPayload {
        CoachNotificationPayload(
            messageId: messageId,
            kind: "snack_rec",
            localDay: "2026-10-06",
            deepLink: AppRouter.coachDeepLink(messageId: messageId, localDay: "2026-10-06"),
            contentHash: "abc",
            mapsQuery: "7-Eleven 2nd Ave",
            body: "7-Eleven, 4 min.",
            categoryIdentifier: CoachNotificationIdentifiers.snackCategory
        )
    }

    @Test func tappingOpensTheDeepLink() {
        #expect(CoachNotificationRouting.route(action(UNNotificationDefaultActionIdentifier, payload: payload))
            == .open(AppRouter.coachDeepLink(messageId: messageId, localDay: "2026-10-06")))
        // Without a payload the identifier still carries the message id.
        #expect(CoachNotificationRouting.route(action(UNNotificationDefaultActionIdentifier))
            == .open(AppRouter.coachDeepLink(messageId: messageId, localDay: nil)))
    }

    @Test func repliesAreTrimmedAndEmptyOnesIgnored() {
        #expect(CoachNotificationRouting.route(action(CoachNotificationIdentifiers.replyAction, reply: "  had eggs \n")) == .reply(text: "had eggs"))
        #expect(CoachNotificationRouting.route(action(CoachNotificationIdentifiers.replyAction, reply: "   ")) == .ignore)
        #expect(CoachNotificationRouting.route(action(CoachNotificationIdentifiers.replyAction)) == .ignore)
    }

    @Test func ackSnoozeAndDirectionsRoute() {
        #expect(CoachNotificationRouting.route(action(CoachNotificationIdentifiers.ackAction)) == .acknowledge(messageId: messageId))
        #expect(CoachNotificationRouting.route(action(CoachNotificationIdentifiers.snoozeAction)) == .snooze(messageId: messageId))
        #expect(CoachNotificationRouting.route(action(CoachNotificationIdentifiers.directionsAction, payload: payload)) == .directions(query: "7-Eleven 2nd Ave"))
        let url = CoachNotificationRouting.directionsURL(query: "7-Eleven 2nd Ave")
        #expect(url?.absoluteString == "https://maps.apple.com/?daddr=7-Eleven%202nd%20Ave&dirflg=w")
    }

    @Test func nonCoachNotificationsAreLeftAlone() {
        let nudge = action(UNNotificationDefaultActionIdentifier, notification: "shudo.nudge.lunch")
        #expect(CoachNotificationRouting.route(nudge) == .ignore)
        #expect(CoachNotificationRouting.route(action(UNNotificationDismissActionIdentifier)) == .ignore)
    }

    @Test func bannersAreSuppressedOnlyWhileTheThreadIsVisible() {
        #expect(CoachNotificationRouting.presentationOptions(isCoach: true, threadVisible: true) == [])
        #expect(CoachNotificationRouting.presentationOptions(isCoach: true, threadVisible: false) == [.banner, .list, .sound])
        #expect(CoachNotificationRouting.presentationOptions(isCoach: false, threadVisible: true) == [.banner, .list, .sound])
    }

    @Test func categoriesCarryTheReplyAction() {
        let categories = CoachNotificationCategories.make()
        let text = categories.first { $0.identifier == CoachNotificationIdentifiers.textCategory }
        let snack = categories.first { $0.identifier == CoachNotificationIdentifiers.snackCategory }
        #expect(text?.actions.map(\.identifier) == ["coach.reply", "coach.ack", "coach.snooze"])
        #expect(text?.actions.first is UNTextInputNotificationAction)
        #expect(snack?.actions.map(\.identifier) == ["coach.directions", "coach.reply"])
        #expect(text?.options.contains(.customDismissAction) == true)
    }
}

struct CoachLocationTests {
    // MARK: Geohash

    @Test func geohashMatchesKnownVectors() {
        // Reference vector from the geohash spec (Jutland, Denmark).
        #expect(Geohash.encode(latitude: 57.64911, longitude: 10.40744, precision: 11) == "u4pruydqqvj")
        #expect(Geohash.encode(latitude: 57.64911, longitude: 10.40744, precision: 7) == "u4pruyd")
        #expect(Geohash.encode(latitude: 0, longitude: 0, precision: 1) == "s")
        #expect(Geohash.encode(latitude: -90, longitude: -180, precision: 3) == "000")
        // Two points ~20 m apart share a 7-char cell.
        #expect(Geohash.encode(latitude: 40.72650, longitude: -73.98690)
            == Geohash.encode(latitude: 40.72660, longitude: -73.98680))
    }

    // MARK: Fix policy

    @Test func fixPolicyNeedsAFreshAccurateReading() {
        #expect(LocationFixPolicy.accepts(accuracy: 35, age: 3, accuracyLimited: false))
        #expect(LocationFixPolicy.accepts(accuracy: 100, age: 119, accuracyLimited: false))
        #expect(!LocationFixPolicy.accepts(accuracy: 101, age: 3, accuracyLimited: false))
        #expect(!LocationFixPolicy.accepts(accuracy: 35, age: 121, accuracyLimited: false))
        #expect(!LocationFixPolicy.accepts(accuracy: -1, age: 1, accuracyLimited: false))
        #expect(LocationFixPolicy.accepts(accuracy: 3_000, age: 10, accuracyLimited: true))
        #expect(!LocationFixPolicy.accepts(accuracy: 8_000, age: 10, accuracyLimited: true))
        #expect(LocationFixPolicy.quality(accuracy: 35, accuracyLimited: false) == .precise)
        #expect(LocationFixPolicy.quality(accuracy: 35, accuracyLimited: true) == .approximate)
    }

    @Test func authorizationMapsToTheSyncStatus() {
        #expect(LocationAuthorization.whenInUse.syncStatus == .whenInUse)
        #expect(LocationAuthorization.always.syncStatus == .whenInUse)
        #expect(LocationAuthorization.restricted.syncStatus == .denied)
        #expect(LocationAuthorization.notDetermined.syncStatus == .notDetermined)
        #expect(!LocationAuthorization.denied.isAuthorized)
    }

    // MARK: Ranking

    private func candidate(
        _ name: String,
        _ category: NearbyStoreCategory,
        distance: Double,
        placeId: String? = nil
    ) -> NearbyStoreCandidate {
        NearbyStoreCandidate(
            placeId: placeId ?? "I\(name.hashValue)-\(distance)",
            name: name,
            category: category,
            latitude: 40.7265 + distance / 111_000,
            longitude: -73.9869,
            addressShort: nil,
            distanceMeters: distance
        )
    }

    @Test func walkingEstimatesAndRounding() {
        #expect(NearbyStorePolicy.estimatedWalkMinutes(distanceMeters: 400) == 7)
        #expect(NearbyStorePolicy.estimatedWalkMinutes(distanceMeters: 0) == 1)
        #expect(NearbyStorePolicy.estimatedWalkMinutes(distanceMeters: 800) == 13)
        #expect(NearbyStorePolicy.roundedDistance(274) == 250)
        #expect(NearbyStorePolicy.roundedDistance(276) == 300)
        #expect(NearbyStorePolicy.roundedDistance(-5) == 0)
    }

    @Test func selectionDedupesCapsPerBucketAndKeepsTwelve() {
        var candidates: [NearbyStoreCandidate] = []
        for index in 0..<6 {
            candidates.append(candidate("Bodega \(index)", .convenience, distance: Double(100 + index)))
            candidates.append(candidate("Market \(index)", .grocery, distance: Double(200 + index)))
            candidates.append(candidate("Cafe \(index)", .cafe, distance: Double(300 + index)))
            candidates.append(candidate("Diner \(index)", .restaurant, distance: Double(400 + index)))
        }
        // The same place found by two searches.
        candidates.append(candidate("Bodega 0", .convenience, distance: 100, placeId: candidates[0].placeId))
        // Too far to walk.
        candidates.append(candidate("Far Away", .pharmacy, distance: 5_000))

        let selected = NearbyStorePolicy.select(candidates.shuffled())
        #expect(selected.count == 12)
        #expect(selected.filter { $0.category.bucket == .quickStop }.count == 4)
        #expect(selected.filter { $0.category == .grocery }.count == 3)
        #expect(selected.filter { $0.category == .cafe }.count == 3)
        #expect(selected.filter { $0.category == .restaurant }.count == 2, "the 12-store cap trims the farthest bucket")
        #expect(selected.map(\.distanceMeters) == selected.map(\.distanceMeters).sorted())
        #expect(Set(selected.map(\.name)).count == selected.count)
        #expect(!selected.contains { $0.name == "Far Away" })
    }

    @Test func etaTargetsAreTheNearestDistinctChains() {
        let selected = [
            candidate("7-Eleven", .convenience, distance: 100),
            candidate("7-Eleven", .convenience, distance: 150, placeId: "other-7-eleven"),
            candidate("CVS", .pharmacy, distance: 200),
            candidate("Starbucks", .cafe, distance: 250),
            candidate("Whole Foods", .grocery, distance: 300),
        ]
        #expect(NearbyStorePolicy.etaTargets(selected).map(\.name) == ["7-Eleven", "CVS", "Starbucks"])
    }

    @Test func storesCarryAStableShortRefAndNoCoordinates() throws {
        let store = candidate("7-Eleven", .convenience, distance: 263, placeId: "I8F2A1C3B4D5E6F70")
        let ref = NearbyStorePolicy.ref(for: store)
        #expect(ref == NearbyStorePolicy.ref(for: store))
        #expect(ref.hasPrefix("p") && ref.count == 11)
        #expect(!ref.contains("I8F2A1C3"))

        let estimated = NearbyStorePolicy.store(from: store, etaMinutes: nil)
        #expect(estimated.walkMinutesSource == .estimate)
        #expect(estimated.walkMinutes == NearbyStorePolicy.estimatedWalkMinutes(distanceMeters: 263))
        #expect(estimated.distanceM == 250)
        #expect(estimated.category == "convenience")

        let measured = NearbyStorePolicy.store(from: store, etaMinutes: 4)
        #expect(measured.walkMinutesSource == .mapkitETA)
        #expect(measured.walkMinutes == 4)

        let context = LocationContext(
            capturedAt: Date(),
            quality: .precise,
            locality: .init(city: "New York", region: "NY", country: "US", timezone: "America/New_York"),
            stores: [measured]
        )
        let json = try #require(String(data: JSONEncoder().encode(context), encoding: .utf8))
        #expect(!json.contains("40.72"))
        #expect(!json.contains("-73.98"))
        #expect(!json.contains(Geohash.encode(latitude: store.latitude, longitude: store.longitude)))
    }

    @Test func cacheExpiresAfterADayAndKeepsAtMostEightCells() {
        let cache = NearbyStoreCache(fileName: nil)
        let now = Date()
        for index in 0..<10 {
            cache.store(NearbyStoreCacheEntry(
                geohash: "dr5reg\(index)",
                capturedAt: now.addingTimeInterval(Double(index) * 60),
                candidates: [],
                locality: nil,
                etas: [:]
            ))
        }
        #expect(cache.entry(for: "dr5reg0", now: now) == nil, "oldest cells are evicted")
        #expect(cache.entry(for: "dr5reg9", now: now) != nil)
        #expect(cache.entry(for: "dr5reg9", now: now.addingTimeInterval(25 * 3600)) == nil)
    }
}
