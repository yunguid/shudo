import SwiftUI

/// "This week": the rolling seven days (calories per logged day as the hero,
/// protein day by day underneath), then the stored weekly recaps. Reached
/// from the Today header.
struct WeeklyInsightsScreen: View {
    let profile: Profile

    @State private var summaries: [WeeklyInsightSummary] = []
    @State private var dailyTotals: [DailyNutritionTotal] = []
    @State private var targetHistory: [DailyMacroTargetSnapshot] = []
    @State private var isLoading: Bool
    @State private var errorMessage: String?

    private let service: SupabaseService
    private let weeklySummaryProvider: any WeeklySummaryProviding
    private let loadsRemotely: Bool

    init(profile: Profile, service: SupabaseService = SupabaseService()) {
        self.profile = profile
        self.service = service
        weeklySummaryProvider = service
        loadsRemotely = true
        _isLoading = State(initialValue: true)
    }

    #if DEBUG
        init(
            previewProfile: Profile,
            summaries: [WeeklyInsightSummary],
            dailyTotals: [DailyNutritionTotal],
            targetHistory: [DailyMacroTargetSnapshot] = []
        ) {
            profile = previewProfile
            service = SupabaseService()
            weeklySummaryProvider = StaticWeeklySummaryProvider(summaries: summaries)
            loadsRemotely = false
            _summaries = State(initialValue: summaries)
            _dailyTotals = State(initialValue: dailyTotals)
            _targetHistory = State(initialValue: targetHistory)
            _isLoading = State(initialValue: false)
        }
    #endif

    private var window: NutrientTrendWeek? {
        NutritionProgressPolicy.runningWeekWindow(
            totals: dailyTotals,
            target: profile.dailyMacroTarget,
            targetHistory: targetHistory,
            timezone: profile.timezone
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                weekCard
                if !summaries.isEmpty {
                    WeeklyRecapList(
                        summaries: summaries,
                        totals: dailyTotals,
                        target: profile.dailyMacroTarget,
                        targetHistory: targetHistory
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background(Design.Color.canvas.ignoresSafeArea())
        .navigationTitle("This week")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard loadsRemotely else { return }
            await load()
        }
        .refreshable {
            guard loadsRemotely else { return }
            await load()
        }
    }

    private var weekCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text("Last 7 days").eyebrowStyle()
                Spacer()
                if let window, window.loggedDayCount > 0 {
                    Text("\(window.loggedDayCount) of 7 logged")
                        .font(Design.Typeface.meta)
                        .foregroundStyle(Design.Color.textTertiary)
                        .monospacedDigit()
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(Design.Color.textSecondary)
            } else if isLoading {
                VStack(alignment: .leading, spacing: 12) {
                    Capsule().fill(Design.Color.surface2).frame(width: 160, height: 28)
                    Capsule().fill(Design.Color.surface2).frame(height: 88)
                }
                .shimmering()
                .accessibilityLabel("Loading this week")
            } else if let window, window.loggedDayCount > 0, let average = window.average {
                let target = window.averageTarget ?? NutrientTrendValues(
                    caloriesKcal: profile.dailyMacroTarget.caloriesKcal,
                    proteinG: profile.dailyMacroTarget.proteinG,
                    carbsG: profile.dailyMacroTarget.carbsG,
                    fatG: profile.dailyMacroTarget.fatG)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        calories(average)
                        Text("kcal / day")
                            .font(.headline)
                            .foregroundStyle(Design.Color.textSecondary)
                        Spacer(minLength: 8)
                        calorieTarget(target)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        calories(average)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("kcal / day")
                                .font(.headline)
                                .foregroundStyle(Design.Color.textSecondary)
                            calorieTarget(target)
                        }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    "Average \(Int(average.caloriesKcal.rounded())) of \(Int(target.caloriesKcal.rounded())) kilocalories per logged day")

                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Protein").eyebrowStyle()
                        Spacer()
                        Text("\(Int(average.proteinG.rounded())) g avg · of \(Int(target.proteinG.rounded()))")
                            .font(Design.Typeface.meta)
                            .foregroundStyle(Design.Color.ember)
                            .monospacedDigit()
                    }
                    ProteinWeekBars(
                        days: ProteinProgress.days(
                            totals: dailyTotals, target: profile.dailyMacroTarget,
                            history: targetHistory, timezone: profile.timezone),
                        timezone: profile.timezone
                    )
                }
            } else {
                Text("Nothing logged in the last seven days.")
                    .font(.subheadline)
                    .foregroundStyle(Design.Color.textSecondary)
            }
        }
        .padding(16)
        .cardSurface(radius: Design.Radius.cardLarge)
    }

    private func calories(_ average: NutrientTrendValues) -> some View {
        Text(Int(average.caloriesKcal.rounded()).formatted())
            .font(Design.Typeface.numeral(.largeTitle, weight: .bold))
            .foregroundStyle(Design.Color.textPrimary)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
    }

    private func calorieTarget(_ target: NutrientTrendValues) -> some View {
        Text("of \(Int(target.caloriesKcal.rounded()).formatted())")
            .font(.footnote)
            .foregroundStyle(Design.Color.textTertiary)
            .monospacedDigit()
    }

    @MainActor
    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            async let totalsRequest = service.fetchDailyNutritionTotals(timezone: profile.timezone)
            async let historyRequest = service.fetchDailyMacroTargetHistory()
            async let summariesRequest = weeklySummaryProvider.fetchWeeklySummaries(
                limit: NutritionProgressPolicy.trendWeekCount
            )
            let loaded = try await (totalsRequest, historyRequest, summariesRequest)
            (dailyTotals, targetHistory, summaries) = loaded
        } catch {
            errorMessage = "Couldn’t load this week. Pull to retry."
        }
        isLoading = false
    }
}

/// Seven days of protein as bars against a dashed target line: ember on a
/// hit (≥ 90%), dimmed under it, a stub where nothing was logged.
private struct ProteinWeekBars: View {
    let days: [ProteinDay]
    let timezone: String

    private static let maxRatio = 1.25
    private static let barHeight: CGFloat = 88

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottom) {
                TargetRule()
                    .stroke(Design.Color.textTertiary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    .frame(height: 1)
                    .offset(y: -Self.barHeight / Self.maxRatio)
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(days) { day in
                        column(day)
                    }
                }
            }
            .frame(height: Self.barHeight + 18, alignment: .bottom)
            HStack(spacing: 8) {
                ForEach(days) { day in
                    Text(day.date, format: Date.FormatStyle(timeZone: TimeZone(identifier: timezone) ?? .current).weekday(.narrow))
                        .font(Design.Typeface.meta)
                        .foregroundStyle(day.id == days.last?.id ? Design.Color.textPrimary : Design.Color.textTertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            .accessibilityHidden(true)
        }
    }

    private func column(_ day: ProteinDay) -> some View {
        let ratio = day.loggedGrams.map { $0 / max(day.targetGrams, 1) }
        let height = ratio.map { max(4, Self.barHeight * min($0, Self.maxRatio) / Self.maxRatio) } ?? 4
        return VStack(spacing: 4) {
            if let grams = day.loggedGrams {
                Text("\(Int(grams.rounded()))")
                    .font(Design.Typeface.numeral(.caption2, weight: .semibold))
                    .foregroundStyle(Design.Color.textSecondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    // Knocks the target rule out behind the number.
                    .padding(.horizontal, 3)
                    .background(Design.Color.surface1)
            }
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(fill(ratio))
                .frame(height: height)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(day))
    }

    private func fill(_ ratio: Double?) -> AnyShapeStyle {
        guard let ratio else { return AnyShapeStyle(Design.Color.surface3) }
        return ratio >= AdherencePolicy.proteinHitRatio
            ? AnyShapeStyle(Design.Color.emberFill)
            : AnyShapeStyle(Design.Color.ember.opacity(0.35))
    }

    private func accessibilityLabel(_ day: ProteinDay) -> String {
        let date = day.date.formatted(
            Date.FormatStyle(timeZone: TimeZone(identifier: timezone) ?? .current).weekday(.wide).month(.abbreviated).day())
        guard let grams = day.loggedGrams else { return "\(date), nothing logged" }
        return "\(date), \(Int(grams.rounded())) of \(Int(day.targetGrams.rounded())) grams of protein"
    }
}

private struct TargetRule: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
    }
}
