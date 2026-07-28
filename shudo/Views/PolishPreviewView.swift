#if DEBUG
import SwiftUI
import UIKit

enum PolishPreviewScreen: String {
    case main
    case detail
    case settings
    case heatmap

    static var launchValue: Self? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-shudoPolishPreview"),
              arguments.indices.contains(flag + 1) else { return nil }
        return Self(rawValue: arguments[flag + 1])
    }
}

struct PolishPreviewAccountDeletionService: AccountDeletionServing {
    func deleteAccount(confirmation: String) async throws {}
}

/// Deterministic offline correction backend for previews and UI tests: it
/// takes a moment to "recalculate" so the timeline's updating state is
/// visible, fails the first attempt when the correction text mentions
/// "fail" (exercising the rollback + retry banner), and succeeds otherwise.
@MainActor
private final class PolishPreviewCorrectionService: EntryReanalysisServing {
    static let shared = PolishPreviewCorrectionService()
    private var attemptCounts: [UUID: Int] = [:]

    func reanalyzeEntry(id: UUID, context: String) async throws -> APIService.ReanalysisResult {
        APIService.ReanalysisResult(entryId: id, status: .complete)
    }

    func correctEntry(
        id: UUID,
        text: String?,
        audioData: Data?,
        clientRequestId: UUID
    ) async throws -> APIService.ReanalysisResult {
        // Long enough for a person (or a UI test polling an animated
        // hierarchy) to see the timeline's updating state before it settles.
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        let attempt = (attemptCounts[id] ?? 0) + 1
        attemptCounts[id] = attempt
        if attempt == 1, text?.localizedCaseInsensitiveContains("fail") == true {
            throw URLError(.notConnectedToInternet)
        }
        return APIService.ReanalysisResult(entryId: id, status: .complete)
    }
}

struct PolishPreviewView: View {
    let screen: PolishPreviewScreen

    init(screen: PolishPreviewScreen) {
        self.screen = screen
        // Seed the fixture avatar before any view loads it, so the Today
        // corner button renders the photo without a network dependency.
        _ = Self.seedFixtureAvatarCache
    }

    private static let seedFixtureAvatarCache: Void = {
        guard let path = profile.avatarPath,
              let data = profilePhoto.jpegData(compressionQuality: 0.9) else { return }
        ProfilePhotoCache.save(data, userId: profile.userId, path: path)
    }()

    var body: some View {
        switch screen {
        case .main:
            TodayView(
                profile: Self.profile,
                previewViewModel: Self.todayViewModel,
                previewEntryDetail: Self.entryDetail
            )
        case .detail:
            NavigationStack {
                EntryDetailView(
                    entryId: Self.completedEntryID,
                    previewDetail: Self.entryDetail
                )
            }
        case .settings:
            NavigationStack {
                AccountView(
                    previewProfile: Self.profile,
                    profilePhoto: Self.profilePhoto,
                    dailyTotals: Self.adherenceTotals
                )
            }
        case .heatmap:
            ZStack {
                AppBackground()
                AdherenceHeatmapView(
                    totals: Self.adherenceTotals,
                    target: Self.profile.dailyMacroTarget,
                    targetHistory: [],
                    timezone: Self.profile.timezone
                )
                .padding(20)
            }
        }
    }

    private static let completedEntryID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    /// The fixture meal after a correction lands: smaller rice portion, so
    /// the card visibly moves from 695 kcal to 560 kcal.
    private static func correctedEntry(id: UUID) -> Entry {
        Entry(
            id: id,
            createdAt: Date().addingTimeInterval(-7_200),
            summary: "Chicken rice bowl",
            imageURL: nil,
            proteinG: 57,
            carbsG: 49,
            fatG: 18,
            caloriesKcal: 560,
            localDay: Self.localDay,
            status: .complete,
            statusMessage: "Ready",
            statusUpdatedAt: Date()
        )
    }

    private static let profile = Profile(
        userId: "00000000-0000-4000-8000-000000000001",
        timezone: "America/New_York",
        dailyMacroTarget: MacroTarget(
            caloriesKcal: 2_520,
            proteinG: 178,
            carbsG: 286,
            fatG: 74
        ),
        units: "imperial",
        heightCM: 182.9,
        weightKG: 84.4,
        targetWeightKG: 81.6,
        displayName: "Luke",
        activityLevel: .active,
        goalType: .lose,
        goalNotes: "Lift four days a week; keep protein high and meals flexible.",
        onboardingStatus: .completed,
        onboardingCompletedAt: Date(),
        avatarPath: "00000000-0000-4000-8000-000000000001/11111111-1111-4111-8111-111111111111.jpg"
    )

    @MainActor
    private static var todayViewModel: TodayViewModel {
        TodayViewModel(
            profile: profile,
            api: APIService(
                supabaseUrl: URL(string: "https://local-preview.invalid")!,
                supabaseAnonKey: "local-preview",
                sessionJWTProvider: { "local-preview" }
            ),
            reanalysis: PolishPreviewCorrectionService.shared,
            fetchEntryById: { id in correctedEntry(id: id) },
            preloadedEntries: [
                Entry(
                    id: completedEntryID,
                    createdAt: Date().addingTimeInterval(-7_200),
                    summary: "Chicken rice bowl",
                    imageURL: nil,
                    proteinG: 58,
                    carbsG: 72,
                    fatG: 19,
                    caloriesKcal: 695,
                    localDay: Self.localDay,
                    status: .complete
                ),
                Entry(
                    id: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
                    createdAt: Date().addingTimeInterval(-4_800),
                    summary: "Chipotle chicken burrito bowl",
                    imageURL: nil,
                    proteinG: 54,
                    carbsG: 88,
                    fatG: 24,
                    caloriesKcal: 800,
                    localDay: Self.localDay,
                    status: .complete,
                    analysisNotes: "Standard portions from the online menu.\n\nOnline sources: [chipotle.com](https://www.chipotle.com/nutrition-calculator)."
                ),
                Entry(
                    id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
                    createdAt: Date().addingTimeInterval(-2_400),
                    summary: "Sweetgreen harvest bowl, look it up",
                    imageURL: nil,
                    proteinG: 0,
                    carbsG: 0,
                    fatG: 0,
                    caloriesKcal: 0,
                    localDay: Self.localDay,
                    status: .analyzing,
                    statusMessage: "Checking nutrition sources",
                    statusUpdatedAt: Date()
                )
            ]
        )
    }

    private static let entryDetail = SupabaseService.EntryDetail(
        createdAt: Date().addingTimeInterval(-7_200),
        imageURL: nil,
        title: "Chipotle chicken burrito bowl",
        rawText: "Chipotle burrito bowl with chicken, white rice, black beans, cheese, and mild salsa. Look up the nutrition online.",
        transcript: "Chipotle bowl with chicken, white rice, black beans, cheese, and mild salsa. Look it up online for the real numbers.",
        proteinG: 54,
        carbsG: 88,
        fatG: 24,
        caloriesKcal: 800,
        items: [
            SupabaseService.EntryDetailItem(
                name: "Grilled chicken",
                amount: "4 oz",
                proteinG: 38,
                carbsG: 0,
                fatG: 7,
                caloriesKcal: 220
            ),
            SupabaseService.EntryDetailItem(
                name: "Cilantro-lime white rice",
                amount: "1¼ cups",
                proteinG: 5,
                carbsG: 52,
                fatG: 3,
                caloriesKcal: 260
            ),
            SupabaseService.EntryDetailItem(
                name: "Black beans",
                amount: "½ cup",
                proteinG: 7,
                carbsG: 22,
                fatG: 1,
                caloriesKcal: 130
            ),
            SupabaseService.EntryDetailItem(
                name: "Cheese and mild salsa",
                amount: "1 serving",
                proteinG: 4,
                carbsG: 14,
                fatG: 13,
                caloriesKcal: 190
            )
        ],
        analysisNotes: "Values follow the restaurant's own nutrition calculator for these exact portions.\n\nOnline sources: [chipotle.com](https://www.chipotle.com/nutrition-calculator), [chipotle.com](https://www.chipotle.com/order/build/burrito-bowl), [nutritionix.com](https://www.nutritionix.com/brand/chipotle-mexican-grill).",
        confidence: 0.9
    )

    private static var profilePhoto: UIImage {
        let size = CGSize(width: 512, height: 512)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor(red: 0.15, green: 0.13, blue: 0.10, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(red: 0.86, green: 0.53, blue: 0.22, alpha: 1).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 96, y: 76, width: 320, height: 320))
            UIColor(red: 0.96, green: 0.91, blue: 0.78, alpha: 1).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 186, y: 155, width: 140, height: 140))
        }
    }

    private static var adherenceTotals: [DailyNutritionTotal] {
        let calendar = Calendar(identifier: .gregorian)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        formatter.dateFormat = "yyyy-MM-dd"
        return (0..<84).compactMap { offset in
            guard offset % 6 != 0,
                  let date = calendar.date(byAdding: .day, value: -offset, to: Date()) else {
                return nil
            }
            let variation = Double((offset % 7) - 3) * 0.035
            return DailyNutritionTotal(
                localDay: formatter.string(from: date),
                proteinG: profile.dailyMacroTarget.proteinG * (0.96 + variation),
                carbsG: profile.dailyMacroTarget.carbsG * (0.94 + variation),
                fatG: profile.dailyMacroTarget.fatG * (0.98 + variation),
                caloriesKcal: profile.dailyMacroTarget.caloriesKcal * (0.95 + variation),
                entryCount: 3
            )
        }
    }

    private static var localDay: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: profile.timezone)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}
#endif
