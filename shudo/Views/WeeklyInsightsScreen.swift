import SwiftUI

/// "This week": the rolling seven days — calories per logged day as the
/// one serif figure, protein day by day as thin bars beneath — then the
/// stored weekly recaps as a ledger. No cards; space does the grouping.
/// Reached from the Today header.
struct WeeklyInsightsScreen: View {
    let profile: Profile

    @State private var summaries: [WeeklyInsightSummary] = []
    @State private var dailyTotals: [DailyNutritionTotal] = []
    @State private var targetHistory: [DailyMacroTargetSnapshot] = []
    @State private var isLoading: Bool
    @State private var errorMessage: String?
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 64
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            VStack(alignment: .leading, spacing: Design.Space.section) {
                week
                if !summaries.isEmpty {
                    WeeklyRecapList(
                        summaries: summaries,
                        totals: dailyTotals,
                        target: profile.dailyMacroTarget,
                        targetHistory: targetHistory
                    )
                    .transition(.ink(reduceMotion: reduceMotion))
                }
            }
            .padding(.horizontal, Design.Space.gutter)
            .padding(.top, Design.Space.l)
            .padding(.bottom, Design.Space.xxxl)
            .animation(Design.Motion.calm(Design.Motion.arrive, reduceMotion: reduceMotion), value: isLoading)
        }
        .background(AppBackground())
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

    // MARK: The week

    @ViewBuilder
    private var week: some View {
        if let errorMessage {
            VStack(alignment: .leading, spacing: Design.Space.s) {
                Text("Last 7 days").eyebrowStyle()
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(Design.Color.textSecondary)
            }
        } else if isLoading {
            VStack(alignment: .leading, spacing: Design.Space.l) {
                Capsule().fill(Design.Color.surface2).frame(width: 90, height: 10)
                Capsule().fill(Design.Color.surface2).frame(width: 180, height: 48)
                Capsule().fill(Design.Color.surface2).frame(height: 96)
                    .padding(.top, Design.Space.xxl)
            }
            .shimmering()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading this week")
        } else if let window, window.loggedDayCount > 0, let average = window.average {
            let target = window.averageTarget ?? NutrientTrendValues(
                caloriesKcal: profile.dailyMacroTarget.caloriesKcal,
                proteinG: profile.dailyMacroTarget.proteinG,
                carbsG: profile.dailyMacroTarget.carbsG,
                fatG: profile.dailyMacroTarget.fatG)
            VStack(alignment: .leading, spacing: Design.Space.section) {
                calorieHero(average: average, target: target, logged: window.loggedDayCount)
                    .transition(.ink(reduceMotion: reduceMotion))
                protein(average: average, target: target)
            }
        } else {
            VStack(alignment: .leading, spacing: Design.Space.s) {
                Text("Last 7 days").eyebrowStyle()
                Text("Nothing logged in the last seven days.")
                    .font(.subheadline)
                    .foregroundStyle(Design.Color.textSecondary)
            }
        }
    }

    /// The week's one figure: average calories on the days that were logged.
    private func calorieHero(average: NutrientTrendValues, target: NutrientTrendValues, logged: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(logged == 7 ? "Last 7 days" : "Last 7 days · \(logged) logged")
                .eyebrowStyle()
            HStack(alignment: .firstTextBaseline, spacing: Design.Space.s) {
                Text(Int(average.caloriesKcal.rounded()).formatted())
                    .font(.system(size: heroSize, weight: .regular, design: .serif))
                    .foregroundStyle(Design.Color.textPrimary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("kcal")
                    .font(Design.Typeface.display(.title3))
                    .foregroundStyle(Design.Color.textSecondary)
            }
            .padding(.top, Design.Space.xs)
            Text("a day on average · of \(Int(target.caloriesKcal.rounded()).formatted())")
                .font(.subheadline)
                .foregroundStyle(Design.Color.textSecondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Average \(Int(average.caloriesKcal.rounded())) of \(Int(target.caloriesKcal.rounded())) kilocalories per logged day, \(logged) of 7 days logged")
    }

    private func protein(average: NutrientTrendValues, target: NutrientTrendValues) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.l) {
            HStack(alignment: .firstTextBaseline) {
                Text("Protein").eyebrowStyle()
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text("\(Int(average.proteinG.rounded())) g a day · of \(Int(target.proteinG.rounded()))")
                    .font(.footnote)
                    .foregroundStyle(Design.Color.textSecondary)
                    .monospacedDigit()
            }
            ProteinWeekBars(
                days: ProteinProgress.days(
                    totals: dailyTotals, target: profile.dailyMacroTarget,
                    history: targetHistory, timezone: profile.timezone),
                timezone: profile.timezone
            )
        }
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

/// Seven days of protein as thin bars under a faint target line:
/// Pernambuco where the day hit (≥ 90%), pale hinoki under it, a small
/// mark where nothing was logged. The accent only lands on a hit.
private struct ProteinWeekBars: View {
    let days: [ProteinDay]
    let timezone: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var grown = false

    private static let maxRatio = 1.25
    private static let barHeight: CGFloat = 96
    private static let barWidth: CGFloat = 10
    private static let labelHeight: CGFloat = 18

    var body: some View {
        VStack(spacing: Design.Space.s) {
            ZStack(alignment: .bottom) {
                TargetRule()
                    .stroke(Design.Color.hinoki.opacity(0.22), style: StrokeStyle(lineWidth: 0.75, dash: [2, 4]))
                    .frame(height: 1)
                    .offset(y: -Self.barHeight / Self.maxRatio)
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(days) { day in
                        column(day)
                    }
                }
            }
            .frame(height: Self.barHeight + Self.labelHeight, alignment: .bottom)
            HStack(spacing: 0) {
                ForEach(days) { day in
                    Text(day.date, format: Date.FormatStyle(timeZone: TimeZone(identifier: timezone) ?? .current).weekday(.narrow))
                        .font(.caption2.weight(day.id == days.last?.id ? .semibold : .regular))
                        .foregroundStyle(day.id == days.last?.id ? Design.Color.textPrimary : Design.Color.textTertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            .accessibilityHidden(true)
        }
        .onAppear {
            withAnimation(Design.Motion.gated(Design.Motion.ring, reduceMotion: reduceMotion)) { grown = true }
        }
    }

    private func column(_ day: ProteinDay) -> some View {
        let ratio = day.loggedGrams.map { $0 / max(day.targetGrams, 1) }
        let height = ratio.map { max(3, Self.barHeight * min($0, Self.maxRatio) / Self.maxRatio) } ?? 2
        let hit = (ratio ?? 0) >= AdherencePolicy.proteinHitRatio
        return VStack(spacing: Design.Space.xs + 2) {
            if let grams = day.loggedGrams {
                Text("\(Int(grams.rounded()))")
                    .font(Design.Typeface.numeral(.caption2, weight: hit ? .medium : .regular))
                    .foregroundStyle(hit ? Design.Color.textSecondary : Design.Color.textTertiary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    // Knocks the target rule out behind the number.
                    .padding(.horizontal, 3)
                    .background(Design.Color.canvas)
            }
            UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3, style: .continuous)
                .fill(fill(ratio, hit: hit))
                .frame(width: day.loggedGrams == nil ? 6 : Self.barWidth, height: grown ? height : 2)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(day))
    }

    private func fill(_ ratio: Double?, hit: Bool) -> Color {
        guard ratio != nil else { return Design.Color.surface3 }
        return hit ? Design.Color.pernambuco : Design.Color.hinoki.opacity(0.22)
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
