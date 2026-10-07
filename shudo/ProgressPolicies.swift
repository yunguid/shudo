import Foundation

// MARK: - Body progress policies
//
// Pure, deterministic math behind the Body tab. The LLM never computes these
// numbers; it only writes words around them. Kilograms internally, the view
// converts for display. Day keys are `yyyy-MM-dd` local-day strings, the same
// keys the server stores, so policy output matches stored rows exactly.

/// Calendar math on `yyyy-MM-dd` keys, anchored at UTC midnight so day
/// arithmetic never crosses a DST boundary.
enum LocalDayMath {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    static func date(_ localDay: String) -> Date? {
        let parts = localDay.split(separator: "-")
        guard localDay.count == 10, parts.count == 3,
            let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
            (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        let date = calendar.date(from: DateComponents(year: year, month: month, day: day))
        // Reject rollovers like 2026-02-31 → 2026-03-03.
        guard let date, string(date) == localDay else { return nil }
        return date
    }

    static func string(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    /// Whole days from `start` to `end` (negative when `end` is earlier).
    static func days(from start: String, to end: String) -> Int? {
        guard let first = date(start), let last = date(end) else { return nil }
        return calendar.dateComponents([.day], from: first, to: last).day
    }

    static func adding(_ days: Int, to localDay: String) -> String? {
        guard let base = date(localDay),
            let shifted = calendar.date(byAdding: .day, value: days, to: base)
        else { return nil }
        return string(shifted)
    }

    /// Today's key in an IANA zone (the user's profile timezone).
    static func today(in timezone: String, now: Date = Date()) -> String {
        var zoned = Calendar(identifier: .gregorian)
        zoned.timeZone = TimeZone(identifier: timezone) ?? .autoupdatingCurrent
        let parts = zoned.dateComponents([.year, .month, .day], from: now)
        return String(
            format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }
}

enum BodyUnits {
    static let poundsPerKilogram = WeightCheckInPolicy.poundsPerKilogram

    static func isImperial(_ units: String) -> Bool { units.lowercased() == "imperial" }
    static func label(_ units: String) -> String { isImperial(units) ? "lb" : "kg" }
    static func display(_ kilograms: Double, units: String) -> Double {
        isImperial(units) ? kilograms * poundsPerKilogram : kilograms
    }
    static func kilograms(pounds: Double) -> Double { pounds / poundsPerKilogram }
    static func pounds(_ kilograms: Double) -> Double { kilograms * poundsPerKilogram }

    /// "162.5", "175" — one decimal unless the value is whole.
    static func format(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? String(format: "%.0f", rounded) : String(format: "%.1f", rounded)
    }

    /// Signed with a real minus sign: "+0.5", "−0.3".
    static func signed(_ value: Double, decimals: Int = 1) -> String {
        let magnitude = String(format: "%.\(decimals)f", abs(value))
        let isZero = Double(magnitude) == 0
        return (isZero ? "+" : value < 0 ? "−" : "+") + magnitude
    }
}

// MARK: - Weight trend

struct WeightSample: Equatable, Sendable {
    let localDay: String
    let kilograms: Double
}

struct WeightTrendPoint: Equatable, Sendable {
    let localDay: String
    let raw: Double
    let trend: Double
}

struct WeightTrendSummary: Equatable, Sendable {
    let latestDay: String
    let latestKG: Double
    let trendKG: Double
    /// kg/week from a least-squares fit; nil until there is enough spread.
    let weeklyRateKG: Double?
    /// Mean of the last 7 days' weigh-ins; nil with fewer than 3 of them.
    let sevenDayAverageKG: Double?
    let weighInsLast7: Int
    let sampleCount: Int
}

enum WeightTrendPolicy {
    static let alpha = 0.1
    static let rateWindowDays = 21
    static let minRateSamples = 5
    static let minRateSpanDays = 10
    /// One weigh-in can move the trend by at most this much input (kg).
    static let outlierKG = 2.5
    static let minAverageSamples = 3
    /// The chart needs this many real weigh-ins before it draws a trend.
    static let minChartSamples = 4

    static func samples(from checkIns: [WeightCheckIn]) -> [WeightSample] {
        var byDay: [String: Double] = [:]
        for checkIn in checkIns {
            guard let weight = checkIn.weightKG, weight.isFinite, weight > 0 else { continue }
            byDay[checkIn.localDay] = weight
        }
        return byDay.map { WeightSample(localDay: $0.key, kilograms: $0.value) }
            .sorted { $0.localDay < $1.localDay }
    }

    /// Gap-aware EMA: a weigh-in after `g` silent days counts like `g` daily
    /// steps (α_eff = 1 − (1 − α)^g), and each step's input is clamped so one
    /// water-logged morning cannot drag the trend.
    static func smoothed(_ samples: [WeightSample]) -> [WeightTrendPoint] {
        let ordered = samples.sorted { $0.localDay < $1.localDay }
        guard let first = ordered.first else { return [] }
        var points = [WeightTrendPoint(localDay: first.localDay, raw: first.kilograms, trend: first.kilograms)]
        var trend = first.kilograms
        var previousDay = first.localDay
        for sample in ordered.dropFirst() {
            let gap = max(1, LocalDayMath.days(from: previousDay, to: sample.localDay) ?? 1)
            let effectiveAlpha = 1 - pow(1 - alpha, Double(gap))
            let delta = min(max(sample.kilograms - trend, -outlierKG), outlierKG)
            trend += effectiveAlpha * delta
            points.append(WeightTrendPoint(localDay: sample.localDay, raw: sample.kilograms, trend: trend))
            previousDay = sample.localDay
        }
        return points
    }

    /// Least-squares slope of raw weigh-ins in the trailing window, as kg/week.
    static func weeklyRate(_ samples: [WeightSample], endingOn endDay: String) -> Double? {
        let window: [(x: Double, y: Double)] = samples.compactMap { sample in
            guard let offset = LocalDayMath.days(from: sample.localDay, to: endDay),
                offset >= 0, offset < rateWindowDays
            else { return nil }
            return (Double(-offset), sample.kilograms)
        }
        guard window.count >= minRateSamples,
            let minX = window.map(\.x).min(), let maxX = window.map(\.x).max(),
            maxX - minX >= Double(minRateSpanDays)
        else { return nil }
        let count = Double(window.count)
        let meanX = window.map(\.x).reduce(0, +) / count
        let meanY = window.map(\.y).reduce(0, +) / count
        let numerator = window.reduce(0) { $0 + ($1.x - meanX) * ($1.y - meanY) }
        let denominator = window.reduce(0) { $0 + ($1.x - meanX) * ($1.x - meanX) }
        guard denominator > 0 else { return nil }
        return numerator / denominator * 7
    }

    static func summary(_ samples: [WeightSample], today: String) -> WeightTrendSummary? {
        let points = smoothed(samples)
        guard let latest = points.last else { return nil }
        let lastWeek = samples.filter {
            guard let offset = LocalDayMath.days(from: $0.localDay, to: today) else { return false }
            return offset >= 0 && offset < 7
        }
        let average =
            lastWeek.count >= minAverageSamples
            ? lastWeek.map(\.kilograms).reduce(0, +) / Double(lastWeek.count) : nil
        return WeightTrendSummary(
            latestDay: latest.localDay,
            latestKG: latest.raw,
            trendKG: latest.trend,
            weeklyRateKG: weeklyRate(samples, endingOn: today),
            sevenDayAverageKG: average,
            weighInsLast7: lastWeek.count,
            sampleCount: points.count
        )
    }
}

// MARK: - Goal trajectory (lean-bulk framing)

enum GoalPhase: String, Sendable {
    case cut, maintain, bulk

    init(goalType: NutritionGoalType) {
        switch goalType {
        case .gain: self = .bulk
        case .lose: self = .cut
        case .maintain: self = .maintain
        }
    }

    /// +1 when the goal is up, −1 when down, 0 for maintenance.
    var direction: Double {
        switch self {
        case .bulk: 1
        case .cut: -1
        case .maintain: 0
        }
    }
}

struct BodyGoal: Equatable, Sendable {
    var phase: GoalPhase
    var startWeightKG: Double?
    var targetWeightKG: Double?
    var startDay: String?
    var targetDay: String?
    /// Unsigned planned pace, kg/week.
    var plannedRateKG: Double

    init(
        phase: GoalPhase,
        startWeightKG: Double? = nil,
        targetWeightKG: Double? = nil,
        startDay: String? = nil,
        targetDay: String? = nil,
        plannedRateKG: Double? = nil
    ) {
        self.phase = phase
        self.startWeightKG = startWeightKG
        self.targetWeightKG = targetWeightKG
        self.startDay = startDay
        self.targetDay = targetDay
        self.plannedRateKG = plannedRateKG ?? TrajectoryPolicy.defaultPlannedRateKG(phase)
    }
}

enum PaceStatus: String, Sendable {
    case ahead, onPace, behind, stalled, wrongDirection, tooFast, drifting
    case goalReached, insufficientData, noGoal
}

struct Trajectory: Equatable, Sendable {
    var status: PaceStatus
    var currentKG: Double?
    /// True when `currentKG` is the profile's self-reported weight, not a trend.
    var currentIsSelfReported = false
    /// Signed distance still to cover (target − current).
    var remainingKG: Double?
    var rateKG: Double?
    var projectedDay: String?
    var requiredRateKG: Double?
    /// Projected day minus the target day: positive = late.
    var daysLate: Int?
}

enum TrajectoryPolicy {
    /// Lean bulk: +0.5 lb/wk planned; the green lane is 0.5–1.5× planned
    /// (+0.25…+0.75 lb/wk). Tuned for Luke's muscle memory near 172 lb.
    static let plannedBulkPoundsPerWeek = 0.5
    static let plannedCutPoundsPerWeek = 1.0
    static let laneLowFactor = 0.5
    static let laneHighFactor = 1.5
    /// Below 10% of planned pace counts as "stalled"; that far the wrong way
    /// counts as "wrong direction".
    static let stallFactor = 0.1
    /// Bulks faster than 0.5% bodyweight/week mostly add fat.
    static let maxBulkPercentPerWeek = 0.005
    static let maxCutPercentPerWeek = 0.01
    static let maxProjectionDays = 730

    static func defaultPlannedRateKG(_ phase: GoalPhase) -> Double {
        switch phase {
        case .bulk: BodyUnits.kilograms(pounds: plannedBulkPoundsPerWeek)
        case .cut: BodyUnits.kilograms(pounds: plannedCutPoundsPerWeek)
        case .maintain: BodyUnits.kilograms(pounds: plannedBulkPoundsPerWeek)
        }
    }

    static func evaluate(
        goal: BodyGoal?,
        trend: WeightTrendSummary?,
        fallbackWeightKG: Double?,
        today: String
    ) -> Trajectory {
        guard let goal, let target = goal.targetWeightKG else {
            return Trajectory(status: .noGoal, currentKG: trend?.trendKG ?? fallbackWeightKG)
        }
        guard let current = trend?.trendKG ?? fallbackWeightKG else {
            return Trajectory(status: .insufficientData)
        }
        var result = Trajectory(
            status: .insufficientData,
            currentKG: current,
            currentIsSelfReported: trend == nil,
            remainingKG: target - current,
            rateKG: trend?.weeklyRateKG
        )
        let direction = goal.phase.direction
        if direction != 0, (target - current) * direction <= 0 {
            result.status = .goalReached
            result.remainingKG = 0
            return result
        }
        if let targetDay = goal.targetDay,
            let days = LocalDayMath.days(from: today, to: targetDay), days > 0
        {
            result.requiredRateKG = (target - current) / (Double(days) / 7)
        }
        guard let rate = trend?.weeklyRateKG else { return result }

        let planned = goal.plannedRateKG
        if direction == 0 {
            result.status = abs(rate) <= planned * laneLowFactor ? .onPace : .drifting
            return result
        }
        let directional = rate * direction
        let ceiling = max(
            planned * laneHighFactor,
            current * (goal.phase == .bulk ? maxBulkPercentPerWeek : maxCutPercentPerWeek)
        )
        // Lane edges count as inside the lane (kg/lb round-trips wobble by an ulp).
        let epsilon = 1e-9
        if directional <= -planned * stallFactor {
            result.status = .wrongDirection
        } else if directional < planned * stallFactor - epsilon {
            result.status = .stalled
        } else if directional < planned * laneLowFactor - epsilon {
            result.status = .behind
        } else if directional > ceiling + epsilon {
            result.status = .tooFast
        } else if directional > planned * laneHighFactor + epsilon {
            result.status = .ahead
        } else {
            result.status = .onPace
        }

        if directional > 0 {
            let days = Int((abs(target - current) / directional * 7).rounded())
            if days <= maxProjectionDays {
                result.projectedDay = LocalDayMath.adding(days, to: today)
                if let projected = result.projectedDay, let targetDay = goal.targetDay {
                    result.daysLate = LocalDayMath.days(from: targetDay, to: projected)
                }
            }
        }
        return result
    }

    /// The shaded on-pace lane from the goal's start, sampled weekly.
    static func lane(goal: BodyGoal, weeks: Int) -> [(day: String, low: Double, high: Double)] {
        guard let start = goal.startWeightKG, let startDay = goal.startDay, weeks > 0,
            goal.phase != .maintain
        else { return [] }
        let direction = goal.phase.direction
        return (0...weeks).compactMap { week in
            guard let day = LocalDayMath.adding(week * 7, to: startDay) else { return nil }
            let low = start + direction * goal.plannedRateKG * laneLowFactor * Double(week)
            let high = start + direction * goal.plannedRateKG * laneHighFactor * Double(week)
            return (day, min(low, high), max(low, high))
        }
    }

}

// MARK: - Streak

enum StreakPolicy {
    /// Consecutive check-in days ending today. Today not done yet is not a
    /// break: the streak then counts through yesterday ("at risk").
    static func current(days: Set<String>, today: String) -> Int {
        var cursor = days.contains(today) ? today : LocalDayMath.adding(-1, to: today)
        var count = 0
        while let day = cursor, days.contains(day) {
            count += 1
            cursor = LocalDayMath.adding(-1, to: day)
        }
        return count
    }

    static func isAtRisk(days: Set<String>, today: String) -> Bool {
        !days.contains(today) && current(days: days, today: today) > 0
    }

    /// Days with a photo or a weight count; one row per day by constraint.
    static func checkInDays(_ checkIns: [WeightCheckIn]) -> Set<String> {
        Set(checkIns.filter { $0.weightKG != nil || $0.progressPhotoPath != nil }.map(\.localDay))
    }
}

// MARK: - Fuel (phase-aware day adherence for the heatmap)

struct FuelDay: Equatable, Sendable {
    enum Calories: Equatable, Sendable { case under, onPlan, over }
    let calories: Calories
    let proteinHit: Bool
    /// Today and not yet a hit: shown, but not judged.
    let isPending: Bool
    /// 0…1, used for the heatmap ramp.
    let score: Double
}

enum AdherencePolicy {
    static let proteinHitRatio = 0.9

    static func calorieBand(_ phase: GoalPhase) -> ClosedRange<Double> {
        switch phase {
        case .bulk: 0.95...1.15
        case .cut: 0.80...1.05
        case .maintain: 0.90...1.10
        }
    }

    static func day(
        total: DailyNutritionTotal?,
        target: MacroTarget,
        phase: GoalPhase,
        isToday: Bool = false
    ) -> FuelDay? {
        guard let total, total.entryCount > 0, target.caloriesKcal > 0 else { return nil }
        let band = calorieBand(phase)
        let calorieRatio = total.caloriesKcal / target.caloriesKcal
        let calories: FuelDay.Calories =
            calorieRatio < band.lowerBound ? .under : calorieRatio > band.upperBound ? .over : .onPlan
        let proteinRatio = target.proteinG > 0 ? total.proteinG / target.proteinG : 1
        let proteinHit = proteinRatio >= proteinHitRatio

        let calorieScore: Double
        switch calories {
        case .onPlan: calorieScore = 1
        case .under: calorieScore = max(0, 1 - (band.lowerBound - calorieRatio) / band.lowerBound * 2)
        case .over: calorieScore = max(0, 1 - (calorieRatio - band.upperBound) / band.upperBound * 2)
        }
        let proteinScore = min(proteinRatio / proteinHitRatio, 1)
        return FuelDay(
            calories: calories,
            proteinHit: proteinHit,
            isPending: isToday && !(proteinHit && calories == .onPlan),
            score: (calorieScore + max(proteinScore, 0)) / 2
        )
    }

    /// Heatmap level 0 (nothing logged) … 4 (calories on plan and protein
    /// hit). One of the two lands on 3 when the other was close, else 2;
    /// missing both is 1 however near the misses were.
    static func level(_ day: FuelDay?) -> Int {
        guard let day else { return 0 }
        switch (day.calories == .onPlan ? 1 : 0) + (day.proteinHit ? 1 : 0) {
        case 2: return 4
        case 1: return day.score >= 0.9 ? 3 : 2
        default: return 1
        }
    }
}
