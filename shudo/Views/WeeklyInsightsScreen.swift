import SwiftUI

/// The dedicated home for weekly insights: a running seven-day window that
/// updates every day at the top, then the stored Monday-anchored summaries
/// browsable week by week beneath it. Reached from the "This week" card at
/// the bottom of Today.
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

    private var runningWindow: NutrientTrendWeek? {
        NutritionProgressPolicy.runningWeekWindow(
            totals: dailyTotals,
            target: profile.dailyMacroTarget,
            targetHistory: targetHistory,
            timezone: profile.timezone
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                runningWindowCard
                WeeklyInsightsView(
                    summaries: summaries,
                    totals: dailyTotals,
                    fallbackTarget: profile.dailyMacroTarget,
                    targetHistory: targetHistory,
                    isLoading: isLoading,
                    errorMessage: errorMessage,
                    onRetry: { Task { await load() } }
                )
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 32)
        }
        .background(AppBackground())
        .navigationTitle("Weekly insights")
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

    /// The live half of the screen: this week so far, refreshed every visit,
    /// while the pager below holds the finished, narrated weeks.
    private var runningWindowCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Last 7 days")
                    .font(.headline)
                    .foregroundStyle(Design.Color.ink)
                Spacer()
                if let window = runningWindow {
                    Text("\(window.loggedDayCount) of 7 days logged")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Design.Color.muted)
                        .monospacedDigit()
                }
            }

            if let window = runningWindow, let average = window.average, window.loggedDayCount > 0 {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("\(Int(average.caloriesKcal.rounded()))")
                        .font(.title.weight(.bold))
                        .foregroundStyle(Design.Color.ink)
                        .monospacedDigit()
                    Text(
                        "kcal/day avg · target \(Int((window.averageTarget?.caloriesKcal ?? profile.dailyMacroTarget.caloriesKcal).rounded()))"
                    )
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Design.Color.muted)
                    .monospacedDigit()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    "Average \(Int(average.caloriesKcal.rounded())) kilocalories per logged day this week"
                )

                HStack(alignment: .top, spacing: 12) {
                    runningMetric(
                        "Protein", average.proteinG,
                        window.averageTarget?.proteinG ?? profile.dailyMacroTarget.proteinG,
                        Design.Color.ringProtein)
                    runningMetric(
                        "Carbs", average.carbsG,
                        window.averageTarget?.carbsG ?? profile.dailyMacroTarget.carbsG,
                        Design.Color.ringCarb)
                    runningMetric(
                        "Fat", average.fatG,
                        window.averageTarget?.fatG ?? profile.dailyMacroTarget.fatG,
                        Design.Color.ringFat)
                }
            } else if isLoading {
                VStack(alignment: .leading, spacing: 9) {
                    Capsule().fill(Design.Color.elevated).frame(width: 180, height: 12)
                    Capsule().fill(Design.Color.elevated).frame(height: 8)
                }
                .shimmering()
                .accessibilityLabel("Loading this week")
            } else {
                Text("Log a meal and this week's running numbers appear here.")
                    .font(.footnote)
                    .foregroundStyle(Design.Color.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .background(
            Design.Color.glassFill,
            in: RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
        )
    }

    private func runningMetric(
        _ label: String, _ value: Double, _ goal: Double, _ color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(.caption)
                .foregroundStyle(Design.Color.muted)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(Int(value.rounded()))")
                    .font(.system(.subheadline, design: .default, weight: .bold))
                    .foregroundStyle(Design.Color.ink)
                    .monospacedDigit()
                Text("/\(Int(goal.rounded()))g")
                    .font(.caption2)
                    .foregroundStyle(Design.Color.muted)
                    .monospacedDigit()
                    .minimumScaleFactor(0.8)
            }
            GeometryReader { geometry in
                Capsule()
                    .fill(Design.Color.rule)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(color)
                            .frame(
                                width: geometry.size.width
                                    * NutritionProgressPolicy.progress(current: value, goal: goal)
                            )
                    }
            }
            .frame(height: 4)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(label), average \(Int(value.rounded())) of \(Int(goal.rounded())) grams per day"
        )
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
            dailyTotals = try await totalsRequest
            targetHistory = try await historyRequest
            summaries = try await summariesRequest
        } catch {
            errorMessage = "Weekly insights couldn’t be loaded."
        }
        isLoading = false
    }
}
