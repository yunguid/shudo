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

private struct PolishPreviewReanalysisService: EntryReanalysisServing {
    func reanalyzeEntry(id: UUID, context: String) async throws -> APIService.ReanalysisResult {
        APIService.ReanalysisResult(entryId: id, status: .analyzing)
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
            TodayView(profile: Self.profile, previewViewModel: Self.todayViewModel)
        case .detail:
            NavigationStack {
                EntryDetailView(
                    entryId: Self.completedEntryID,
                    previewDetail: Self.entryDetail,
                    reanalysisService: PolishPreviewReanalysisService()
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
                    id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
                    createdAt: Date().addingTimeInterval(-2_400),
                    summary: "Greek yogurt, berries, honey",
                    imageURL: nil,
                    proteinG: 0,
                    carbsG: 0,
                    fatG: 0,
                    caloriesKcal: 0,
                    localDay: Self.localDay,
                    status: .analyzing,
                    statusMessage: "Updating nutrition estimate",
                    statusUpdatedAt: Date(),
                    analysisPreview: "Checking the portion and topping details…"
                )
            ]
        )
    }

    private static let entryDetail = SupabaseService.EntryDetail(
        createdAt: Date().addingTimeInterval(-7_200),
        imageURL: nil,
        title: "Chicken rice bowl",
        rawText: "Chicken thigh, jasmine rice, vegetables, and a little sesame sauce.",
        transcript: "Chicken rice bowl with about two cups of rice, grilled chicken thigh, mixed vegetables, and sesame sauce.",
        proteinG: 58,
        carbsG: 72,
        fatG: 19,
        caloriesKcal: 695,
        items: [
            SupabaseService.EntryDetailItem(
                name: "Grilled chicken thigh",
                amount: "170 g",
                proteinG: 43,
                carbsG: 0,
                fatG: 13,
                caloriesKcal: 305
            ),
            SupabaseService.EntryDetailItem(
                name: "Jasmine rice",
                amount: "1½ cups cooked",
                proteinG: 7,
                carbsG: 68,
                fatG: 1,
                caloriesKcal: 310
            ),
            SupabaseService.EntryDetailItem(
                name: "Mixed vegetables and sesame sauce",
                amount: "1 serving",
                proteinG: 8,
                carbsG: 4,
                fatG: 5,
                caloriesKcal: 80
            )
        ],
        analysisNotes: "Portions are estimated from the description. Sauce and cooking oil create most of the uncertainty.",
        confidence: 0.82
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
