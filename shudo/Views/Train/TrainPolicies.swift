import Foundation

// MARK: - Pure Train policies (unit-tested in shudoTests/TrainPolicyTests.swift)
//
// Everything the Train tab derives from rows lives here as deterministic
// functions: calendar math, session rotation, double-progression targets,
// e1RM/PR detection for display, the week strip, polling cadence, list
// merging and card copy. The server stays authoritative for stored PRs and
// burn; these exist so the UI is instant and offline-correct.

// MARK: Calendar

enum TrainCalendar {
    /// Gregorian, Monday-first, in the profile's timezone.
    static func calendar(timezone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? .autoupdatingCurrent
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    static func localDay(for date: Date, timezone: String) -> String {
        let components = calendar(timezone: timezone).dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else {
            return "1970-01-01"
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    static func isLocalDay(_ text: String) -> Bool {
        text.count == 10 && text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }

    /// Start of that local day in the timezone.
    static func date(fromLocalDay localDay: String, timezone: String) -> Date? {
        let parts = localDay.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        return calendar(timezone: timezone).date(from: components)
    }

    static func adding(days: Int, to localDay: String, timezone: String) -> String? {
        let calendar = calendar(timezone: timezone)
        guard let start = date(fromLocalDay: localDay, timezone: timezone),
              let shifted = calendar.date(byAdding: .day, value: days, to: start) else { return nil }
        return Self.localDay(for: shifted, timezone: timezone)
    }

    /// The seven local days (Monday … Sunday) of the week containing `date`.
    static func weekDays(containing date: Date, timezone: String) -> [String] {
        let calendar = calendar(timezone: timezone)
        let startOfDay = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: startOfDay)  // 1 = Sunday
        let offsetFromMonday = (weekday + 5) % 7
        guard let monday = calendar.date(byAdding: .day, value: -offsetFromMonday, to: startOfDay) else {
            return []
        }
        return (0..<7).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: monday).map {
                localDay(for: $0, timezone: timezone)
            }
        }
    }

    static let weekdayInitials = ["M", "T", "W", "T", "F", "S", "S"]
}

// MARK: Strength math + lift identity

enum StrengthMath {
    /// Epley is reliable for low-to-moderate reps; past 12 it overstates.
    static let maximumRepsForE1RM = 12

    /// Epley estimated one-rep max: w × (1 + reps / 30). A single is its own
    /// max. Nil for bodyweight sets, zero reps or high-rep sets.
    static func e1rm(weight: Double, reps: Int) -> Double? {
        guard weight > 0, weight.isFinite, reps >= 1, reps <= maximumRepsForE1RM else { return nil }
        if reps == 1 { return weight }
        return weight * (1 + Double(reps) / 30)
    }

    /// e1RM of a working set, in pounds.
    static func e1rmPounds(_ set: ActivitySet) -> Double? {
        guard set.isWorking, let pounds = set.weightInPounds else { return nil }
        return e1rm(weight: pounds, reps: set.reps)
    }

    static func convert(pounds: Double, to unit: WeightUnit) -> Double {
        unit == .kg ? pounds / WeightUnit.poundsPerKilogram : pounds
    }

    /// "185", "92.5", "1,005".
    static func formatWeight(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() {
            return Int(rounded).formatted()
        }
        return rounded.formatted(.number.precision(.fractionLength(1)))
    }

    /// Plates come in 1.25 kg steps; never suggest a jump smaller than that.
    static func kilogramIncrement(fromPounds pounds: Double?) -> Double {
        guard let pounds, pounds > 0 else { return 2.5 }
        let kilograms = pounds / WeightUnit.poundsPerKilogram
        return max(1.25, (kilograms / 1.25).rounded() * 1.25)
    }
}

enum LiftIdentity {
    /// Folds naming noise so "Barbell Bench Press", "bench press" and
    /// "Bench-press" compare equal, while "DB bench" stays its own lift.
    static func normalizedName(_ name: String) -> String {
        var text = name.lowercased()
        text = text.replacingOccurrences(of: "dumbbells", with: "db")
        text = text.replacingOccurrences(of: "dumbbell", with: "db")
        text = text.replacingOccurrences(of: "barbell", with: "")
        if text.hasPrefix("bb ") { text.removeFirst(3) }
        let scalars = text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        var folded = String(String.UnicodeScalarView(scalars))
        if folded.count > 3, folded.hasSuffix("s") { folded.removeLast() }
        return folded
    }

    static func matches(plannedName: String, plannedKey: String?, loggedName: String, loggedKey: String?) -> Bool {
        if let plannedKey, let loggedKey, !plannedKey.isEmpty,
           plannedKey.caseInsensitiveCompare(loggedKey) == .orderedSame {
            return true
        }
        let planned = normalizedName(plannedName)
        return !planned.isEmpty && planned == normalizedName(loggedName)
    }

    static func matches(_ planned: PlannedExercise, _ logged: ActivityExercise) -> Bool {
        matches(plannedName: planned.name, plannedKey: planned.key, loggedName: logged.name, loggedKey: logged.key)
    }

    /// Groups exercises across history: a catalog key when any log carried
    /// one for this name, otherwise the normalized name.
    static func groupKeys(for activities: [Activity]) -> (ActivityExercise) -> String {
        var keyByName: [String: String] = [:]
        for activity in activities {
            for exercise in activity.exercises {
                if let key = exercise.key?.lowercased(), !key.isEmpty {
                    keyByName[normalizedName(exercise.name)] = key
                }
            }
        }
        return { exercise in
            if let key = exercise.key?.lowercased(), !key.isEmpty { return key }
            let name = normalizedName(exercise.name)
            return keyByName[name] ?? "name:\(name)"
        }
    }
}

// MARK: Session rotation

enum SessionRotationPolicy {
    /// Plan session ids in the order they were done (oldest first). Logs
    /// that never reached the server or failed analysis don't advance the
    /// rotation; ones still being read do (they were logged against it).
    static func completedSessionIds(from activities: [Activity]) -> [String] {
        activities
            .filter { $0.countsTowardHistory && $0.planSessionId != nil }
            .sorted { lhs, rhs in
                lhs.occurredAt == rhs.occurredAt ? lhs.createdAt < rhs.createdAt : lhs.occurredAt < rhs.occurredAt
            }
            .compactMap(\.planSessionId)
    }

    /// Rotation queue, not weekday slots: next up is whatever follows the
    /// last session done, so a missed day never breaks the plan. Ids no
    /// longer in the rotation (an older plan) are skipped. When a session id
    /// appears more than once in the rotation, the occurrence whose
    /// preceding entries best match recent history wins.
    static func nextSessionId(rotation: [String], completedSessionIds: [String]) -> String? {
        guard !rotation.isEmpty else { return nil }
        let known = Set(rotation)
        let history = completedSessionIds.filter { known.contains($0) }
        guard let last = history.last else { return rotation[0] }
        let candidates = rotation.indices.filter { rotation[$0] == last }
        guard var best = candidates.first else { return rotation[0] }
        if candidates.count > 1 {
            var bestScore = -1
            for position in candidates {
                var score = 0
                var rotationIndex = position
                var historyIndex = history.count - 1
                while historyIndex >= 0, score < rotation.count, rotation[rotationIndex] == history[historyIndex] {
                    score += 1
                    historyIndex -= 1
                    rotationIndex = (rotationIndex - 1 + rotation.count) % rotation.count
                }
                if score > bestScore {
                    bestScore = score
                    best = position
                }
            }
        }
        return rotation[(best + 1) % rotation.count]
    }

    static func nextSession(plan: TrainingPlanDoc, completedSessionIds: [String]) -> TrainingSession? {
        nextSessionId(rotation: plan.rotation, completedSessionIds: completedSessionIds)
            .flatMap(plan.session(id:))
    }

    static func nextSession(plan: TrainingPlanDoc, activities: [Activity]) -> TrainingSession? {
        nextSession(plan: plan, completedSessionIds: completedSessionIds(from: activities))
    }
}

// MARK: Double progression

struct LastPerformance: Equatable, Sendable {
    var sets: [ActivitySet]
    var localDay: String
    var activityId: UUID
}

struct LiftTarget: Equatable, Identifiable, Sendable {
    enum Basis: Equatable, Sendable {
        /// No history: work inside the rep range at a weight you own.
        case firstTime
        /// Every working set hit the top of the range: add load, reset reps.
        case increaseWeight(by: Double)
        /// Same load, one more rep on the weakest set.
        case addReps
        /// Hit the top of the range on fewer sets than planned.
        case addSet
    }

    var exercise: PlannedExercise
    var sets: Int
    var reps: [Int]
    var weight: Double?
    var unit: WeightUnit
    var basis: Basis
    var last: LastPerformance?

    var id: String { exercise.key ?? exercise.name }

    var weightText: String? {
        weight.map { StrengthMath.formatWeight($0) + (unit == .kg ? " kg" : "") }
    }

    /// "4×8 @ 190", "185 × 8/8/8/7", "3×12", or the plan range "4×6–8".
    var prescription: String {
        if basis == .firstTime { return exercise.prescription }
        let uniform = Set(reps).count <= 1
        let repText = reps.map(String.init).joined(separator: "/")
        if let weightText {
            return uniform ? "\(sets)×\(reps.first ?? 0) @ \(weightText)" : "\(weightText) × \(repText)"
        }
        return uniform ? "\(sets)×\(reps.first ?? 0)" : repText
    }

    /// "+5 lb", "+1 rep", "+1 set"; nil the first time.
    var deltaLabel: String? {
        switch basis {
        case .firstTime: return nil
        case .increaseWeight(let amount):
            return "+\(StrengthMath.formatWeight(amount)) \(unit.rawValue)"
        case .addReps: return "+1 rep"
        case .addSet: return "+1 set"
        }
    }

    /// The load goes up this session — the one progression worth flagging.
    var addsWeight: Bool {
        if case .increaseWeight = basis { return true }
        return false
    }
}

enum DoubleProgressionPolicy {
    static let defaultIncrementLb = 5.0

    /// The most recent completed log of this exercise with working sets.
    static func lastPerformance(of exercise: PlannedExercise, in activities: [Activity]) -> LastPerformance? {
        let settled = activities
            .filter { $0.status == .complete && $0.localState == nil }
            .sorted { $0.occurredAt > $1.occurredAt }
        for activity in settled {
            for logged in activity.exercises where LiftIdentity.matches(exercise, logged) {
                let working = logged.sets.filter(\.isWorking)
                if !working.isEmpty {
                    return LastPerformance(sets: logged.sets, localDay: activity.localDay, activityId: activity.id)
                }
            }
        }
        return nil
    }

    static func nextTarget(
        for exercise: PlannedExercise,
        last: LastPerformance?,
        preferredUnit: WeightUnit = .lb
    ) -> LiftTarget {
        let plannedSets = max(1, exercise.sets)
        let repMin = max(1, min(exercise.repMin, exercise.repMax))
        let repMax = max(repMin, exercise.repMax)
        let working = last?.sets.filter(\.isWorking) ?? []
        guard !working.isEmpty else {
            return LiftTarget(
                exercise: exercise,
                sets: plannedSets,
                reps: Array(repeating: repMax, count: plannedSets),
                weight: nil,
                unit: preferredUnit,
                basis: .firstTime,
                last: nil
            )
        }

        guard let topPounds = working.compactMap(\.weightInPounds).max() else {
            // Bodyweight: the progression is reps.
            let reps = bumpWeakest(fitted(working.map(\.reps), count: plannedSets), cap: nil)
            return LiftTarget(
                exercise: exercise, sets: plannedSets, reps: reps, weight: nil,
                unit: preferredUnit, basis: .addReps, last: last)
        }

        let atTop = working.filter { abs(($0.weightInPounds ?? 0) - topPounds) < 0.01 }
        let unit = atTop.first?.unit ?? preferredUnit
        let weight = atTop.first?.weight ?? StrengthMath.convert(pounds: topPounds, to: unit)
        let allAtTopOfRange = atTop.allSatisfy { $0.reps >= repMax }

        if allAtTopOfRange, atTop.count >= plannedSets {
            let increment = unit == .kg
                ? StrengthMath.kilogramIncrement(fromPounds: exercise.incrementLb)
                : (exercise.incrementLb ?? defaultIncrementLb)
            return LiftTarget(
                exercise: exercise,
                sets: plannedSets,
                reps: Array(repeating: repMin, count: plannedSets),
                weight: weight + increment,
                unit: unit,
                basis: .increaseWeight(by: increment),
                last: last
            )
        }
        if allAtTopOfRange {
            return LiftTarget(
                exercise: exercise,
                sets: plannedSets,
                reps: Array(repeating: repMax, count: plannedSets),
                weight: weight,
                unit: unit,
                basis: .addSet,
                last: last
            )
        }
        let reps = bumpWeakest(fitted(atTop.map(\.reps), count: plannedSets).map { min($0, repMax) }, cap: repMax)
        return LiftTarget(
            exercise: exercise, sets: plannedSets, reps: reps, weight: weight,
            unit: unit, basis: .addReps, last: last)
    }

    static func targets(
        for session: TrainingSession,
        history: [Activity],
        preferredUnit: WeightUnit = .lb
    ) -> [LiftTarget] {
        session.exercises.map { exercise in
            nextTarget(
                for: exercise,
                last: lastPerformance(of: exercise, in: history),
                preferredUnit: preferredUnit
            )
        }
    }

    /// Pads (with the weakest observed count) or trims to the planned sets.
    private static func fitted(_ reps: [Int], count: Int) -> [Int] {
        guard let floor = reps.min() else { return Array(repeating: 1, count: count) }
        if reps.count >= count { return Array(reps.prefix(count)) }
        return reps + Array(repeating: floor, count: count - reps.count)
    }

    /// +1 on the weakest set (the earliest one when tied, so the targets keep
    /// fatigue's descending shape: 8/8/7/6 → 8/8/7/7), never past `cap`.
    private static func bumpWeakest(_ reps: [Int], cap: Int?) -> [Int] {
        guard let minimum = reps.min(), let index = reps.firstIndex(of: minimum) else { return reps }
        var bumped = reps
        bumped[index] = cap.map { min($0, minimum + 1) } ?? minimum + 1
        return bumped
    }
}

// MARK: Personal records

struct PersonalBest: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var bestSet: ActivitySet
    /// Nil for bodyweight-only lifts (ranked by reps instead).
    var e1rmPounds: Double?
    var localDay: String
    var activityId: UUID
    /// Set within the recent window and beat an earlier best.
    var isFresh: Bool
}

enum PRPolicy {
    /// The big lifts lead the board even when a machine moves more weight.
    static let defaultPriorityLifts = [
        "Bench press", "Back squat", "Squat", "Deadlift", "Overhead press", "Barbell row",
    ]

    /// Main lifts of a plan (each session's first exercise, in rotation
    /// order), followed by the defaults.
    static func priorityLifts(for plan: TrainingPlanDoc?) -> [String] {
        let leads = plan?.orderedSessions.compactMap { $0.exercises.first?.name } ?? []
        return leads + defaultPriorityLifts
    }

    /// Best e1RM per lift across history (bodyweight lifts by best reps).
    /// Lifts named in `priority` lead in that order; the rest follow by
    /// e1RM, heaviest first, then bodyweight lifts by reps.
    static func board(
        from activities: [Activity],
        freshSince: String? = nil,
        priority: [String] = defaultPriorityLifts
    ) -> [PersonalBest] {
        let settled = activities
            .filter { $0.status == .complete && $0.localState == nil }
            .sorted { $0.occurredAt < $1.occurredAt }
        let groupKey = LiftIdentity.groupKeys(for: settled)
        var bests: [String: PersonalBest] = [:]
        var improved: [String: Bool] = [:]

        for activity in settled {
            for exercise in activity.exercises {
                let key = groupKey(exercise)
                let working = exercise.workingSets
                guard !working.isEmpty else { continue }
                let candidate: (set: ActivitySet, e1rm: Double?)? = {
                    let weighted = working.compactMap { set in StrengthMath.e1rmPounds(set).map { (set, $0) } }
                    if let top = weighted.max(by: { $0.1 < $1.1 }) { return (top.0, top.1) }
                    if working.allSatisfy({ $0.weightInPounds == nil }),
                       let top = working.max(by: { $0.reps < $1.reps }) {
                        return (top, nil)
                    }
                    return nil
                }()
                guard let candidate else { continue }
                let fresh = PersonalBest(
                    id: key, name: exercise.name, bestSet: candidate.set, e1rmPounds: candidate.e1rm,
                    localDay: activity.localDay, activityId: activity.id, isFresh: false)
                guard let existing = bests[key] else {
                    bests[key] = fresh
                    improved[key] = false
                    continue
                }
                if beats(fresh, existing) {
                    bests[key] = fresh
                    improved[key] = true
                } else {
                    bests[key]?.name = exercise.name  // keep the most recent label
                }
            }
        }

        let normalizedPriority = priority.map(LiftIdentity.normalizedName)
        func rank(_ best: PersonalBest) -> Int {
            normalizedPriority.firstIndex(of: LiftIdentity.normalizedName(best.name)) ?? Int.max
        }
        return bests.values
            .map { best in
                var best = best
                if let freshSince {
                    best.isFresh = (improved[best.id] ?? false) && best.localDay >= freshSince
                }
                return best
            }
            .sorted { lhs, rhs in
                let (lhsRank, rhsRank) = (rank(lhs), rank(rhs))
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                switch (lhs.e1rmPounds, rhs.e1rmPounds) {
                case let (l?, r?): return l == r ? lhs.name < rhs.name : l > r
                case (.some, .none): return true
                case (.none, .some): return false
                case (.none, .none):
                    return lhs.bestSet.reps == rhs.bestSet.reps
                        ? lhs.name < rhs.name : lhs.bestSet.reps > rhs.bestSet.reps
                }
            }
    }

    /// Client-side PRs for one activity against everything before it:
    /// a higher e1RM (weighted) or more reps (bodyweight). A first-ever log
    /// establishes a baseline; it is not a PR.
    static func detectPRs(
        in activity: Activity,
        history: [Activity],
        displayUnit: WeightUnit = .lb
    ) -> [ActivityPR] {
        let prior = history.filter {
            $0.id != activity.id && $0.status == .complete && $0.localState == nil
                && $0.occurredAt < activity.occurredAt
        }
        let groupKey = LiftIdentity.groupKeys(for: prior + [activity])
        var priorBestE1RM: [String: Double] = [:]
        var priorBestReps: [String: Int] = [:]
        for row in prior {
            for exercise in row.exercises {
                let key = groupKey(exercise)
                for set in exercise.workingSets {
                    if let e1rm = StrengthMath.e1rmPounds(set) {
                        priorBestE1RM[key] = max(priorBestE1RM[key] ?? 0, e1rm)
                    } else if set.weightInPounds == nil {
                        priorBestReps[key] = max(priorBestReps[key] ?? 0, set.reps)
                    }
                }
            }
        }

        var records: [ActivityPR] = []
        var reported = Set<String>()
        for exercise in activity.exercises {
            let key = groupKey(exercise)
            guard !reported.contains(key) else { continue }
            let working = exercise.workingSets
            if let best = working.compactMap(StrengthMath.e1rmPounds).max(),
               let previous = priorBestE1RM[key], best > previous + 0.5 {
                records.append(ActivityPR(
                    exercise: exercise.name,
                    kind: .e1rm,
                    value: StrengthMath.convert(pounds: best, to: displayUnit).rounded(),
                    unit: displayUnit.rawValue,
                    previous: StrengthMath.convert(pounds: previous, to: displayUnit).rounded()))
                reported.insert(key)
            } else if working.allSatisfy({ $0.weightInPounds == nil }),
                      let reps = working.map(\.reps).max(),
                      let previous = priorBestReps[key], reps > previous {
                records.append(ActivityPR(
                    exercise: exercise.name, kind: .reps, value: Double(reps), unit: "reps",
                    previous: Double(previous)))
                reported.insert(key)
            }
        }
        return records
    }

    private static func beats(_ candidate: PersonalBest, _ existing: PersonalBest) -> Bool {
        switch (candidate.e1rmPounds, existing.e1rmPounds) {
        case let (c?, e?): return c > e + 0.5
        case (.some, .none): return true
        case (.none, .some): return false
        case (.none, .none): return candidate.bestSet.reps > existing.bestSet.reps
        }
    }
}

// MARK: Week strip

struct TrainingWeekDay: Equatable, Identifiable, Sendable {
    var localDay: String
    var weekdayInitial: String
    /// Plan session letter ("U") when a plan session was logged that day.
    var marker: String?
    /// Kind symbol for an off-plan session or other activity.
    var symbolName: String?
    var trained: Bool
    var isToday: Bool
    var isFuture: Bool

    var id: String { localDay }
}

struct TrainingWeekProgress: Equatable, Sendable {
    var days: [TrainingWeekDay]
    var completed: Int
    var target: Int?

    /// "2 of 4" against the plan; nil without one (the strip says it).
    var countLabel: String? {
        target.map { "\(completed) of \($0)" }
    }

    static let empty = TrainingWeekProgress(days: [], completed: 0, target: nil)
}

enum TrainingWeekPolicy {
    /// A training session for the week strip: logged against the plan, or a
    /// lifting/HIIT session. The 10-minute morning bike is not a session.
    static func isTrainingSession(_ activity: Activity) -> Bool {
        activity.countsTowardHistory
            && (activity.planSessionId != nil || activity.kind == .strength || activity.kind == .hiit)
    }

    /// Distinct days this week with a training session (a split log of one
    /// workout counts once).
    static func sessionsThisWeek(activities: [Activity], now: Date, timezone: String) -> Int {
        let week = Set(TrainCalendar.weekDays(containing: now, timezone: timezone))
        return Set(activities.filter { isTrainingSession($0) && week.contains($0.localDay) }.map(\.localDay)).count
    }

    static func progress(
        activities: [Activity],
        plan: TrainingPlanDoc?,
        now: Date,
        timezone: String
    ) -> TrainingWeekProgress {
        let weekDays = TrainCalendar.weekDays(containing: now, timezone: timezone)
        let today = TrainCalendar.localDay(for: now, timezone: timezone)
        let inWeek = activities.filter { $0.countsTowardHistory && weekDays.contains($0.localDay) }
        let days = weekDays.enumerated().map { index, day in
            let rows = inWeek.filter { $0.localDay == day }.sorted { $0.occurredAt < $1.occurredAt }
            let sessions = rows.filter(isTrainingSession)
            let planMarker = sessions.lazy
                .compactMap { $0.planSessionId.flatMap { plan?.session(id: $0) }?.marker }
                .first
            let symbol: String? = planMarker == nil ? (sessions.first ?? rows.first)?.kind.symbolName : nil
            return TrainingWeekDay(
                localDay: day,
                weekdayInitial: TrainCalendar.weekdayInitials[index],
                marker: planMarker,
                symbolName: symbol,
                trained: !sessions.isEmpty,
                isToday: day == today,
                isFuture: day > today
            )
        }
        return TrainingWeekProgress(
            days: days,
            completed: days.filter(\.trained).count,
            target: plan?.sessionsPerWeek
        )
    }
}

// MARK: Polling cadence

enum ActivityPollingPolicy {
    static let initialDelay: UInt64 = 650_000_000
    static let maximumDelay: UInt64 = 3_000_000_000
    static let maximumConsecutiveErrors = 12
    static let timeout: TimeInterval = 300

    /// 650 ms, then ×1.5 per poll up to 3 s.
    static func nextDelay(after current: UInt64) -> UInt64 {
        min(current + current / 2, maximumDelay)
    }
}

// MARK: List merge

enum ActivityTimelineMerge {
    /// Server rows overlaid with locally tracked ones. A local-only card whose
    /// client_request_id already has a server row is dropped (the request
    /// landed but its response was lost); otherwise the newer row wins.
    static func merge(loaded: [Activity], overlay: [Activity]) -> [Activity] {
        var byId: [UUID: Activity] = [:]
        for row in loaded { byId[row.id] = row }
        let serverRequestIds = Set(loaded.compactMap(\.clientRequestId))
        for row in overlay {
            if row.isLocalOnly, let requestId = row.clientRequestId, serverRequestIds.contains(requestId) {
                continue
            }
            if let existing = byId[row.id] {
                // Ties go to the tracked row while it is local or still
                // processing (it carries the optimistic title and local state).
                let overlayIsNewer = row.updatedAt > existing.updatedAt
                    || (row.updatedAt == existing.updatedAt
                        && (row.localState != nil || row.status == .processing))
                if overlayIsNewer { byId[row.id] = row }
            } else {
                byId[row.id] = row
            }
        }
        return sorted(Array(byId.values))
    }

    static func sorted(_ rows: [Activity]) -> [Activity] {
        rows.sorted { lhs, rhs in
            if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt > rhs.occurredAt }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}

// MARK: Card copy

enum ActivitySummaryFormatter {
    static let kilometersToMiles = 0.621_371

    /// "52 min", "1 h 5 min".
    static func durationText(minutes: Double) -> String {
        let total = max(0, Int(minutes.rounded()))
        guard total >= 60 else { return "\(total) min" }
        let hours = total / 60
        let remainder = total % 60
        return remainder == 0 ? "\(hours) h" : "\(hours) h \(remainder) min"
    }

    /// "3.1 mi" (imperial) / "5 km" (metric).
    static func distanceText(kilometers: Double, units: String) -> String {
        let metric = units.lowercased() == "metric"
        let value = metric ? kilometers : kilometers * kilometersToMiles
        let rounded = (value * 10).rounded() / 10
        let text = rounded == rounded.rounded() && rounded >= 10
            ? Int(rounded).formatted()
            : rounded.formatted(.number.precision(.fractionLength(1)))
        return "\(text) \(metric ? "km" : "mi")"
    }

    /// "Barbell bench press" → "Bench press"; "Dumbbell row" → "DB row".
    static func shortLiftName(_ name: String) -> String {
        var text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["barbell ", "bb "] where text.lowercased().hasPrefix(prefix) {
            let rest = String(text.dropFirst(prefix.count))
            // "Barbell bench press" → "Bench press", but "Barbell row" stays.
            if rest.split(separator: " ").count >= 2 { text = rest }
        }
        if text.lowercased().hasPrefix("dumbbell ") {
            text = "DB " + text.dropFirst("dumbbell ".count)
        }
        guard let first = text.first else { return name }
        return first.uppercased() + text.dropFirst()
    }

    /// "185×8", "100 kg×5", "×12" for bodyweight.
    static func setText(_ set: ActivitySet, units: String) -> String {
        guard let weight = set.weight, weight > 0 else { return "×\(set.reps)" }
        let bareUnit: WeightUnit = WeightUnit(preference: units)
        let suffix = set.unit == bareUnit ? "" : " \(set.unit.rawValue)"
        return "\(StrengthMath.formatWeight(weight))\(suffix)×\(set.reps)"
    }

    /// "185", or "100 kg" when the set's unit isn't the bare-number unit.
    static func weightLabel(_ set: ActivitySet, units: String) -> String? {
        guard let weight = set.weight, weight > 0 else { return nil }
        let suffix = set.unit == WeightUnit(preference: units) ? "" : " \(set.unit.rawValue)"
        return StrengthMath.formatWeight(weight) + suffix
    }

    /// One exercise in a line: "4×8 @ 185", "185 × 8/8/7", "3×12",
    /// or the top set ("205×5 top") when loads varied.
    static func exerciseSummary(_ exercise: ActivityExercise, units: String) -> String {
        let working = exercise.workingSets
        guard let first = working.first else { return "" }
        let reps = working.map(\.reps)
        let uniformReps = Set(reps).count == 1
        let repText = reps.map(String.init).joined(separator: "/")
        let loads = Set(working.map { ($0.weightInPounds ?? 0).rounded() })
        if loads.count == 1 {
            if let weight = weightLabel(first, units: units) {
                return uniformReps ? "\(working.count)×\(reps[0]) @ \(weight)" : "\(weight) × \(repText)"
            }
            return uniformReps ? "\(working.count)×\(reps[0])" : repText
        }
        guard let top = exercise.topSet else { return repText }
        return setText(top, units: units) + " top"
    }

    /// Every working set of one exercise: the collapsed form when the load
    /// held ("4×8 @ 185", "25 × 8/7/7/6"), each set when it changed
    /// ("135×10, 185×8, 205×5").
    static func setsSummary(_ exercise: ActivityExercise, units: String) -> String {
        let working = exercise.workingSets
        let loads = Set(working.map { ($0.weightInPounds ?? 0).rounded() })
        guard loads.count > 1 else { return exerciseSummary(exercise, units: units) }
        return working.map { setText($0, units: units) }.joined(separator: ", ")
    }

    /// "Bench press 185×8" — the lead lift's top set; nil without lifts.
    static func leadLift(of activity: Activity, units: String) -> (text: String, otherLifts: Int)? {
        let exercises = activity.exercises.filter { !$0.workingSets.isEmpty }
        guard let lead = exercises.first, let top = lead.topSet else { return nil }
        var text = shortLiftName(lead.name)
        if top.weightInPounds != nil {
            text += " " + setText(top, units: units)
        } else {
            let reps = lead.workingSets.map(\.reps)
            text += Set(reps).count == 1 ? " \(reps.count)×\(reps[0])" : " ×\(reps.max() ?? 0)"
        }
        return (text, exercises.count - 1)
    }

    /// "Bench press 185×8 · +4 lifts" for lifting, "32 min · 3.1 mi" for
    /// everything else.
    static func subtitle(for activity: Activity, units: String) -> String? {
        if let lead = leadLift(of: activity, units: units) {
            let others = lead.otherLifts
            return others > 0 ? "\(lead.text) · +\(others) lift\(others == 1 ? "" : "s")" : lead.text
        }
        return effortLine(for: activity, units: units)
    }

    /// The activity card's one stat line: "Bench press 185×8 · 61 min" for
    /// lifting, "32 min · 3.1 mi" for everything else.
    static func statLine(for activity: Activity, units: String) -> String? {
        if let lead = leadLift(of: activity, units: units) {
            return [lead.text, metaDuration(for: activity)].compactMap { $0 }.joined(separator: " · ")
        }
        return effortLine(for: activity, units: units)
    }

    /// "32 min · 3.1 mi", or the effort ("Hard") when nothing was measured.
    private static func effortLine(for activity: Activity, units: String) -> String? {
        var parts: [String] = []
        if let minutes = activity.durationMin, minutes > 0 { parts.append(durationText(minutes: minutes)) }
        if let km = activity.distanceKm, km > 0 { parts.append(distanceText(kilometers: km, units: units)) }
        if parts.isEmpty, let intensity = activity.intensity { parts.append(intensity.label) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Duration for a lifting log (cardio already leads with it).
    static func metaDuration(for activity: Activity) -> String? {
        guard activity.exercises.contains(where: { !$0.workingSets.isEmpty }),
              let minutes = activity.durationMin, minutes > 0 else { return nil }
        return durationText(minutes: minutes)
    }
}
