import Foundation
import ImageIO
import Testing
import UIKit

@testable import shudo

struct BodyCheckInTests {
    private static let userId = "00000000-0000-4000-8000-000000000001"

    // MARK: Save payload

    @Test func photoOnlySaveOmitsTheWeightKey() {
        let captured = Date(timeIntervalSince1970: 1_791_300_000)
        let payload = SupabaseService.bodyCheckInPayload(
            userId: Self.userId,
            draft: BodyCheckInDraft(
                localDay: "2026-10-06", weightKG: nil, photoJPEG: Data([0xFF, 0xD8]),
                pose: .frontRelaxed, capturedAt: captured),
            photoPath: "\(Self.userId)/2026-10-06/progress-11111111-2222-4333-8444-555555555555.jpg"
        )
        #expect(payload["weight_kg"] == nil)
        #expect(payload.keys.contains("weight_kg") == false)
        #expect(payload["user_id"] as? String == Self.userId)
        #expect(payload["local_day"] as? String == "2026-10-06")
        #expect(payload["photo_pose"] as? String == "front_relaxed")
        #expect((payload["progress_photo_path"] as? String)?.hasSuffix(".jpg") == true)
        #expect(payload["photo_captured_at"] as? String != nil)
        #expect(payload["note"] == nil)
        // Must serialize as JSON without a null weight.
        let json = String(data: try! JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
        #expect(!json.contains("weight_kg"))
    }

    @Test func weightOnlySaveNeverTouchesPhotoColumns() {
        let payload = SupabaseService.bodyCheckInPayload(
            userId: Self.userId,
            draft: BodyCheckInDraft(localDay: "2026-10-06", weightKG: 73.94, pose: .side, capturedAt: Date()),
            photoPath: nil
        )
        #expect(payload["weight_kg"] as? Double == 73.94)
        for key in ["progress_photo_path", "photo_pose", "photo_captured_at"] {
            #expect(payload[key] == nil, "\(key) must be omitted")
        }
    }

    @Test func notesAreTrimmedAndCapped() {
        let blank = SupabaseService.bodyCheckInPayload(
            userId: Self.userId, draft: BodyCheckInDraft(localDay: "2026-10-06", note: "   \n"), photoPath: nil)
        #expect(blank["note"] == nil)
        let long = SupabaseService.bodyCheckInPayload(
            userId: Self.userId,
            draft: BodyCheckInDraft(localDay: "2026-10-06", note: "  " + String(repeating: "a", count: 1_200)),
            photoPath: nil)
        #expect((long["note"] as? String)?.count == WeightCheckInPolicy.noteLimit)
    }

    @Test func goalPayloadOnlySendsWhatChangedAndCanClear() throws {
        #expect(try SupabaseService.bodyGoalPayload().isEmpty)
        let set = try SupabaseService.bodyGoalPayload(
            goalStartedOn: .some("2026-09-01"), goalStartWeightKG: .some(73.7088))
        #expect(set["goal_started_on"] as? String == "2026-09-01")
        #expect(set["goal_start_weight_kg"] as? Double == 73.71)
        #expect(set["goal_date"] == nil)
        let cleared = try SupabaseService.bodyGoalPayload(goalDate: .some(nil))
        #expect(cleared["goal_date"] is NSNull)
        #expect(try SupabaseService.bodyGoalPayload(physiqueAIReviewEnabled: true)["physique_ai_review_enabled"] as? Bool == true)
        #expect(throws: (any Error).self) { try SupabaseService.bodyGoalPayload(goalDate: .some("2026-13-01")) }
        #expect(throws: (any Error).self) { try SupabaseService.bodyGoalPayload(goalStartWeightKG: .some(5)) }
    }

    // MARK: Path grammar

    @Test func photoPathsAreLowercaseOwnedAndStrict() throws {
        let upperUser = Self.userId.uppercased()
        let fileId = try #require(UUID(uuidString: "ABCDEF12-2222-4333-8444-555555555555"))
        let path = try SupabaseService.weightPhotoPath(userId: upperUser, localDay: "2026-10-06", fileId: fileId)
        #expect(path == "00000000-0000-4000-8000-000000000001/2026-10-06/progress-abcdef12-2222-4333-8444-555555555555.jpg")
        #expect(path == path.lowercased())
        #expect(SupabaseService.weightPhotoPathBelongsToUser(path, userId: upperUser))
        #expect(!SupabaseService.weightPhotoPathBelongsToUser(path, userId: "00000000-0000-4000-8000-000000000002"))
        #expect(!SupabaseService.weightPhotoPathBelongsToUser(path.uppercased(), userId: Self.userId))
        #expect(!SupabaseService.weightPhotoPathBelongsToUser("\(Self.userId)/2026-10-06/../x.jpg", userId: Self.userId))
        #expect(!SupabaseService.weightPhotoPathBelongsToUser(path.replacingOccurrences(of: ".jpg", with: ".png"), userId: Self.userId))
        #expect(throws: (any Error).self) { try SupabaseService.weightPhotoPath(userId: "nope", localDay: "2026-10-06") }
        #expect(throws: (any Error).self) { try SupabaseService.weightPhotoPath(userId: Self.userId, localDay: "10/06/2026") }
    }

    @Test func storageURLsTargetTheCheckInBucket() throws {
        let service = SupabaseService()
        let path = try SupabaseService.weightPhotoPath(userId: Self.userId, localDay: "2026-10-06")
        let download = service.bodyStorageURL(operation: "object/authenticated", path: path).absoluteString
        #expect(download.hasSuffix("/storage/v1/object/authenticated/weight-checkin-photos/\(path)"))
    }

    @Test func photoTransportNeverUsesASharedDiskCache() {
        let configuration = SupabaseService.bodyPhotoSession.configuration
        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(SupabaseService.bodyPhotoSession !== URLSession.shared)
    }

    // MARK: Model decoding

    @Test func decodesPhotoOnlyRowsWithNullWeightAndTheNewColumns() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            [
                "id": "11111111-2222-4333-8444-555555555555",
                "local_day": "2026-10-06",
                "weight_kg": NSNull(),
                "progress_photo_path": "\(Self.userId)/2026-10-06/progress-11111111-2222-4333-8444-555555555555.jpg",
                "note": "Pumped from legs",
                "photo_pose": "front_relaxed",
                "photo_captured_at": "2026-10-06T11:12:00.000Z",
                "coach_review": [
                    "headline": "Delts are filling out.",
                    "bulk_quality": "clean",
                    "observations": [["region": "shoulders", "evidence": "Rounder caps"], "Waist unchanged"],
                ],
                "coach_reviewed_at": "2026-10-06T12:00:00Z",
                "created_at": "2026-10-06T11:12:30.000Z",
                "updated_at": "2026-10-06T11:12:30.000Z",
            ],
            [
                "id": "22222222-2222-4333-8444-555555555555",
                "local_day": "2026-10-05",
                "weight_kg": 73.94,
                "progress_photo_path": NSNull(),
                "created_at": "2026-10-05T11:00:00Z",
                "updated_at": "2026-10-05T11:00:00Z",
            ],
            [
                // Neither observation: dropped.
                "id": "33333333-2222-4333-8444-555555555555",
                "local_day": "2026-10-04",
                "weight_kg": NSNull(),
                "progress_photo_path": NSNull(),
                "created_at": "2026-10-04T11:00:00Z",
                "updated_at": "2026-10-04T11:00:00Z",
            ],
        ])
        let parsed = try SupabaseService.parseWeightCheckIns(data)
        #expect(parsed.count == 2)
        let photoOnly = try #require(parsed.first)
        #expect(photoOnly.weightKG == nil)
        #expect(photoOnly.hasPhoto && !photoOnly.hasWeight)
        #expect(photoOnly.note == "Pumped from legs")
        #expect(photoOnly.photoPose == .frontRelaxed)
        #expect(photoOnly.photoCapturedAt != nil)
        #expect(photoOnly.coachReview?.headline == "Delts are filling out.")
        #expect(photoOnly.coachReview?.bulkQuality == "clean")
        #expect(photoOnly.coachReview?.observations == ["Rounder caps", "Waist unchanged"])
        #expect(photoOnly.coachReviewedAt != nil)
        let weightOnly = parsed[1]
        #expect(weightOnly.weightKG == 73.94)
        #expect(!weightOnly.hasPhoto)
        #expect(weightOnly.photoPose == nil)
    }

    @Test func decodesBaseColumnRowsFromOlderServers() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            [
                "id": "11111111-2222-4333-8444-555555555555",
                "local_day": "2026-07-30",
                "weight_kg": "82.45",
                "progress_photo_path": NSNull(),
                "created_at": "2026-07-30T12:00:00.000Z",
                "updated_at": "2026-07-30T12:05:00.000Z",
            ]
        ])
        let parsed = try SupabaseService.parseWeightCheckIns(data)
        #expect(parsed.first?.weightKG == 82.45)
        #expect(parsed.first?.note == nil)
        #expect(PhysiquePose(rawValue: "front") == .front)
    }

    @Test func goalSettingsDecodeTheTwoPointOhColumns() {
        let settings = SupabaseService.parseBodyGoalSettings([
            "goal_type": "gain",
            "target_weight_kg": "79.38",
            "weight_kg": 73.71,
            "goal_date": NSNull(),
            "goal_started_on": "2026-09-01",
            "goal_start_weight_kg": "73.71",
            "physique_ai_review_enabled": true,
        ])
        #expect(settings.goalType == .gain)
        #expect(settings.targetWeightKG == 79.38)
        #expect(settings.goalStartedOn == "2026-09-01")
        #expect(settings.goalStartWeightKG == 73.71)
        #expect(settings.goalDate == nil)
        #expect(settings.physiqueAIReviewEnabled)
    }

    // MARK: Encrypted cache

    private func temporaryCache() -> BodyPhotoCache {
        BodyPhotoCache(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("BodyPhotosTest-\(UUID().uuidString)", isDirectory: true))
    }

    @Test func cacheWritesProtectedBackupExcludedFiles() throws {
        let cache = temporaryCache()
        defer { cache.removeAll() }
        let path = try SupabaseService.weightPhotoPath(userId: Self.userId, localDay: "2026-10-06")
        try cache.save(Data([0xFF, 0xD8, 0xFF, 0xD9]), userId: Self.userId, path: path)

        #expect(cache.load(userId: Self.userId, path: path) == Data([0xFF, 0xD8, 0xFF, 0xD9]))
        #expect(BodyPhotoCache.writeOptions.contains(.completeFileProtection))
        #expect(BodyPhotoCache.writeOptions.contains(.atomic))
        #expect(BodyPhotoCache.directoryAttributes[.protectionKey] as? FileProtectionType == .complete)
        #if !targetEnvironment(simulator)
            // Only devices report data-protection classes; the Simulator returns nil.
            let file = try #require(cache.fileURL(userId: Self.userId, path: path))
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            #expect(attributes[.protectionKey] as? FileProtectionType == .complete)
        #endif
        let values = try cache.root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        #expect(BodyPhotoCache.shared?.root.path.contains("Application Support") == true)
    }

    @Test func cacheRejectsTraversalAndClears() throws {
        let cache = temporaryCache()
        #expect(cache.fileURL(userId: Self.userId, path: "../../etc/passwd") == nil)
        #expect(cache.fileURL(userId: Self.userId, path: "a/../../b.jpg") == nil)
        #expect(throws: (any Error).self) { try cache.save(Data([1]), userId: Self.userId, path: "../x") }
        let path = try SupabaseService.weightPhotoPath(userId: Self.userId, localDay: "2026-10-06")
        try cache.save(Data([1]), userId: Self.userId, path: path)
        cache.remove(userId: Self.userId, path: path)
        #expect(cache.load(userId: Self.userId, path: path) == nil)
        try cache.save(Data([1]), userId: Self.userId, path: path)
        cache.removeAll()
        #expect(!FileManager.default.fileExists(atPath: cache.root.path))
    }

    // MARK: Photo encoding

    @Test func uploadEncodingStripsMetadataAndFitsTheBucket() throws {
        let size = CGSize(width: 3_024, height: 4_032)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.brown.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            for index in 0..<200 {
                UIColor(hue: CGFloat(index) / 200, saturation: 0.6, brightness: 0.8, alpha: 1).setFill()
                context.fill(CGRect(x: CGFloat(index * 15), y: CGFloat(index * 20), width: 40, height: 40))
            }
        }
        let jpeg = try #require(BodyPhotoEncoder.jpeg(from: image))
        #expect(jpeg.count <= SupabaseService.maximumWeightPhotoBytes)
        #expect(SupabaseService.profilePhotoDataIsJPEG(jpeg))
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        #expect(tiff?[kCGImagePropertyTIFFMake] == nil)
        #expect(tiff?[kCGImagePropertyTIFFModel] == nil)
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        #expect(max(width, height) <= 1_600)
    }

    // MARK: Pose alignment

    private func pose(hipX: CGFloat = 0.5, head: CGFloat = 0.1, feet: CGFloat = 0.9, wristOffset: CGFloat = 0.12) -> BodyPoseObservation {
        BodyPoseObservation(joints: [
            .nose: CGPoint(x: hipX, y: head),
            .leftHip: CGPoint(x: hipX - 0.06, y: 0.5), .rightHip: CGPoint(x: hipX + 0.06, y: 0.5),
            .leftWrist: CGPoint(x: hipX - 0.06 - wristOffset, y: 0.5),
            .rightWrist: CGPoint(x: hipX + 0.06 + wristOffset, y: 0.5),
            .leftAnkle: CGPoint(x: hipX - 0.05, y: feet), .rightAnkle: CGPoint(x: hipX + 0.05, y: feet),
        ])
    }

    @Test func poseAlignmentGivesOneFixAtATime() {
        #expect(BodyPoseAlignmentPolicy.hint(nil) == .noBody)
        #expect(BodyPoseAlignmentPolicy.hint(pose()) == .aligned)
        #expect(BodyPoseAlignmentPolicy.hint(pose(feet: 0.99)) == .stepBack)
        #expect(BodyPoseAlignmentPolicy.hint(pose(head: 0.3, feet: 0.8)) == .comeCloser)
        #expect(BodyPoseAlignmentPolicy.hint(pose(hipX: 0.38)) == .stepLeft)
        #expect(BodyPoseAlignmentPolicy.hint(pose(hipX: 0.62)) == .stepRight)
        #expect(BodyPoseAlignmentPolicy.hint(pose(wristOffset: 0.01)) == .armsOut)
        var noFeet = pose()
        noFeet.joints[.leftAnkle] = nil
        noFeet.joints[.rightAnkle] = nil
        #expect(BodyPoseAlignmentPolicy.hint(noFeet) == .stepBack)
    }

    // MARK: Check-in flow

    @Test func flowDraftsSendOnlyWhatWasProvided() {
        let now = Date()

        // Photo with a blank weight: no weight, photo columns present.
        let photoOnly = BodyCheckInFlow.draft(
            localDay: "2026-10-06", weightKG: nil, includesPhoto: true, pose: .side, capturedAt: now)
        #expect(photoOnly.weightKG == nil)
        #expect(photoOnly.pose == .side)
        #expect(photoOnly.capturedAt == now)
        #expect(photoOnly.note == nil)  // an earlier note is never touched
        let photoPayload = SupabaseService.bodyCheckInPayload(
            userId: Self.userId, draft: photoOnly, photoPath: "\(Self.userId)/2026-10-06/progress-x.jpg")
        #expect(photoPayload["note"] == nil && photoPayload["weight_kg"] == nil)

        // "Add weight" later: weight only, no photo columns.
        let weightOnly = BodyCheckInFlow.draft(
            localDay: "2026-10-06", weightKG: 74.2, includesPhoto: false, pose: .frontRelaxed, capturedAt: now)
        #expect(weightOnly.weightKG == 74.2)
        #expect(weightOnly.pose == nil && weightOnly.capturedAt == nil && weightOnly.photoJPEG == nil)
        let payload = SupabaseService.bodyCheckInPayload(userId: Self.userId, draft: weightOnly, photoPath: nil)
        #expect(Set(payload.keys) == ["user_id", "local_day", "weight_kg"])
    }

    @MainActor
    @Test func viewModelMergesSavesAndPhotoRemovals() async throws {
        let today = "2026-10-06"
        let now = Date()
        let photo = WeightCheckIn(
            id: UUID(), localDay: today, weightKG: nil,
            progressPhotoPath: "\(Self.userId)/\(today)/progress-11111111-2222-4333-8444-555555555555.jpg",
            createdAt: now, updatedAt: now)
        let service = FixtureBodyService(checkIns: [photo], nutrition: BodyNutritionHistory())
        let model = BodyViewModel(
            previewProfile: BodyFixtures.profile,
            settings: BodyGoalSettings(profile: BodyFixtures.profile),
            checkIns: [photo],
            nutrition: BodyNutritionHistory(),
            summaries: [],
            service: service,
            today: today)
        #expect(model.snapshot.todayCheckIn?.hasWeight == false)

        let saved = try await service.save(
            BodyCheckInDraft(localDay: today, weightKG: 74), replacing: photo, updatesProfileWeight: true)
        model.applySaved(saved)
        #expect(model.checkIns.count == 1)
        #expect(model.snapshot.todayCheckIn?.hasWeight == true)
        #expect(model.snapshot.todayCheckIn?.hasPhoto == true)
        #expect(model.snapshot.weighInCount == 1)

        await model.removePhoto(try #require(model.snapshot.todayCheckIn))
        #expect(model.snapshot.todayCheckIn?.hasPhoto == false)
        #expect(model.snapshot.todayCheckIn?.weightKG == 74)
        #expect(model.snapshot.photoCheckIns.isEmpty)
    }

    // MARK: Body snapshot

    @Test func snapshotAnchorsTheBulkAndFindsTheGhost() {
        let profile = Profile(
            userId: Self.userId, timezone: "America/New_York", dailyMacroTarget: .defaultDaily,
            units: "imperial", weightKG: BodyUnits.kilograms(pounds: 165), targetWeightKG: BodyUnits.kilograms(pounds: 175),
            goalType: .gain)
        let now = Date()
        func row(_ day: String, weight: Double? = nil, photo: Bool = true) -> WeightCheckIn {
            WeightCheckIn(
                id: UUID(), localDay: day, weightKG: weight.map(BodyUnits.kilograms(pounds:)),
                progressPhotoPath: photo ? "\(Self.userId)/\(day)/progress-x.jpg" : nil,
                createdAt: now, updatedAt: now)
        }
        let checkIns = [row("2026-10-06"), row("2026-10-05"), row("2026-10-03", weight: 163, photo: false)]
        let selfReported = BodyGoalSettings(
            goalType: .gain, targetWeightKG: BodyUnits.kilograms(pounds: 175),
            selfReportedWeightKG: BodyUnits.kilograms(pounds: 162.5))

        let snapshot = BodySnapshot.make(profile: profile, settings: selfReported, checkIns: checkIns, today: "2026-10-06")
        #expect(snapshot.todayCheckIn?.localDay == "2026-10-06")
        #expect(snapshot.ghostCheckIn?.localDay == "2026-10-05")
        #expect(snapshot.photoCheckIns.map(\.localDay) == ["2026-10-06", "2026-10-05"])
        #expect(snapshot.streak == 2)
        #expect(snapshot.goal?.phase == .bulk)
        // No stored anchor: the first weigh-in beats the drifting profile weight.
        #expect(snapshot.goal?.startWeightKG == BodyUnits.kilograms(pounds: 163))
        #expect(snapshot.goal?.startDay == "2026-10-03")
        #expect(snapshot.dayNumber == 4)
        #expect(!snapshot.showsTrendChart)

        var anchored = selfReported
        anchored.goalStartWeightKG = BodyUnits.kilograms(pounds: 162.5)
        anchored.goalStartedOn = "2026-09-01"
        let stored = BodySnapshot.make(profile: profile, settings: anchored, checkIns: [], today: "2026-10-06")
        #expect(stored.goal?.startWeightKG == BodyUnits.kilograms(pounds: 162.5))
        #expect(stored.dayNumber == 36)
        #expect(stored.trajectory.status == .insufficientData)
        #expect(stored.trajectory.currentIsSelfReported)
        #expect(stored.meterCurrentKG == BodyUnits.kilograms(pounds: 162.5))
    }
}
