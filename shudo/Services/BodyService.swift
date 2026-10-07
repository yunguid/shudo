import SwiftUI
import UIKit

struct BodyNutritionHistory: Equatable, Sendable {
    var totals: [DailyNutritionTotal] = []
    var targetHistory: [DailyMacroTargetSnapshot] = []
}

/// Everything the Body tab reads and writes. The live implementation talks
/// to Supabase through RLS and the encrypted photo cache; previews and tests
/// inject fixtures.
protocol BodyServicing: Sendable {
    func checkIns(limit: Int) async throws -> [WeightCheckIn]
    func goalSettings() async throws -> BodyGoalSettings
    func nutrition(timezone: String) async throws -> BodyNutritionHistory
    func weeklySummaries(limit: Int) async throws -> [WeeklyInsightSummary]
    /// JPEG bytes for a check-in photo path (cache first, then authenticated download).
    func photoData(path: String) async throws -> Data
    func save(
        _ draft: BodyCheckInDraft,
        replacing existing: WeightCheckIn?,
        updatesProfileWeight: Bool
    ) async throws -> WeightCheckIn
    /// Returns the remaining row, or nil when the row was photo-only and is gone.
    func removePhoto(_ checkIn: WeightCheckIn) async throws -> WeightCheckIn?
    /// Locks the goal's start point the first time Body opens without one.
    func anchorGoal(startedOn: String, startWeightKG: Double) async throws
}

struct LiveBodyService: BodyServicing {
    let supabase: SupabaseService

    init(supabase: SupabaseService = SupabaseService()) {
        self.supabase = supabase
    }

    func checkIns(limit: Int) async throws -> [WeightCheckIn] {
        try await supabase.fetchWeightCheckIns(limit: limit)
    }

    func goalSettings() async throws -> BodyGoalSettings {
        try await supabase.fetchBodyGoalSettings()
    }

    func nutrition(timezone: String) async throws -> BodyNutritionHistory {
        async let totals = supabase.fetchDailyNutritionTotals(timezone: timezone)
        async let history = supabase.fetchDailyMacroTargetHistory()
        return BodyNutritionHistory(totals: try await totals, targetHistory: (try? await history) ?? [])
    }

    func weeklySummaries(limit: Int) async throws -> [WeeklyInsightSummary] {
        try await supabase.fetchWeeklySummaries(limit: limit)
    }

    func photoData(path: String) async throws -> Data {
        let userId = try supabase.currentUserId()
        let cache = BodyPhotoCache.shared
        if let cached = cache?.load(userId: userId, path: path) { return cached }
        let data = try await supabase.fetchCheckInPhoto(path: path)
        try? cache?.save(data, userId: userId, path: path)
        return data
    }

    func save(
        _ draft: BodyCheckInDraft,
        replacing existing: WeightCheckIn?,
        updatesProfileWeight: Bool
    ) async throws -> WeightCheckIn {
        let saved = try await supabase.saveBodyCheckIn(
            draft, replacing: existing, updatesProfileWeight: updatesProfileWeight)
        if let userId = try? supabase.currentUserId(), let cache = BodyPhotoCache.shared {
            // Seed the cache with the bytes just uploaded: no round trip to show it.
            if let jpeg = draft.photoJPEG, let path = saved.progressPhotoPath {
                try? cache.save(jpeg, userId: userId, path: path)
            }
            if let old = existing?.progressPhotoPath, old != saved.progressPhotoPath {
                cache.remove(userId: userId, path: old)
            }
        }
        return saved
    }

    func removePhoto(_ checkIn: WeightCheckIn) async throws -> WeightCheckIn? {
        let remaining = try await supabase.removeCheckInPhoto(checkIn)
        if let path = checkIn.progressPhotoPath, let userId = try? supabase.currentUserId() {
            BodyPhotoCache.shared?.remove(userId: userId, path: path)
        }
        return remaining
    }

    func anchorGoal(startedOn: String, startWeightKG: Double) async throws {
        try await supabase.updateBodyGoal(goalStartedOn: .some(startedOn), goalStartWeightKG: .some(startWeightKG))
    }
}

/// Upload encoding for physique photos. `ImageProcessor` redraws through
/// `UIGraphicsImageRenderer`, which drops EXIF, GPS and maker metadata; the
/// quality steps keep the result under the bucket's 4 MB cap.
enum BodyPhotoEncoder {
    static let steps: [(maxPixelSize: Int, quality: CGFloat)] = [(1_600, 0.82), (1_400, 0.72), (1_200, 0.62)]

    static func jpeg(from image: UIImage) -> Data? {
        for step in steps {
            guard let data = ImageProcessor.uploadJPEGData(
                from: [image], maxPixelSize: step.maxPixelSize, quality: step.quality)
            else { return nil }
            if data.count <= SupabaseService.maximumWeightPhotoBytes { return data }
        }
        return nil
    }
}

/// Decoded, downsampled photos for the Body tab, memoized in memory only.
@MainActor
final class BodyPhotoLoader: ObservableObject {
    private let service: any BodyServicing
    private let memory = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    init(service: any BodyServicing) {
        self.service = service
        memory.countLimit = 120
    }

    private static func key(_ path: String, _ maxPixel: Int) -> NSString { "\(maxPixel)|\(path)" as NSString }

    func cachedImage(path: String, maxPixel: Int) -> UIImage? {
        memory.object(forKey: Self.key(path, maxPixel))
    }

    func image(path: String, maxPixel: Int) async -> UIImage? {
        let key = Self.key(path, maxPixel)
        if let hit = memory.object(forKey: key) { return hit }
        if let running = inFlight[key as String] { return await running.value }
        let service = service
        let task = Task<UIImage?, Never> {
            guard let data = try? await service.photoData(path: path) else { return nil }
            return await Task.detached(priority: .userInitiated) {
                ImageProcessor.downsample(data: data, maxPixelSize: maxPixel)
            }.value
        }
        inFlight[key as String] = task
        let image = await task.value
        inFlight[key as String] = nil
        if let image { memory.setObject(image, forKey: key) }
        return image
    }

    /// Seeds a just-captured photo so the hero shows it without a download.
    func insert(_ image: UIImage, path: String) {
        for size in [BodyPhotoSize.thumb, BodyPhotoSize.hero, BodyPhotoSize.full] {
            memory.setObject(image, forKey: Self.key(path, size))
        }
    }

    func clear() {
        memory.removeAllObjects()
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
    }
}

enum BodyPhotoSize {
    static let thumb = 360
    static let hero = 600
    static let full = 1_600
}
