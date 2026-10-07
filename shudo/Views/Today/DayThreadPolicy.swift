import Foundation

// MARK: - The day thread: one chronological conversation per local day
//
// Today's screen merges four sources into one iMessage-style thread: the
// coach's messages (and Luke's replies), his meals, his workouts, and the
// day's body check-in. Everything here is pure so ordering, grouping and
// timestamps are unit-tested; the views only render `DayThreadRow`s.

/// Which side of the conversation a row sits on.
enum ThreadSide: Equatable, Sendable {
    /// Shudo: left, avatar gutter.
    case coach
    /// Luke: right (texts, meal receipts, workouts, check-ins).
    case me
    /// Centered system pills ("Goals updated").
    case center
}

enum DayThreadItem: Identifiable, Equatable {
    case message(CoachMessage)
    case pending(CoachPendingSend)
    case meal(Entry)
    case activity(Activity)
    case checkIn(WeightCheckIn)
    /// Shudo is thinking / writing (`label` = tool status, e.g. "Checking what's near you…").
    case typing(label: String?, at: Date)

    var id: String {
        switch self {
        case .message(let message): return "msg-\(message.id.uuidString)"
        case .pending(let pending): return "msg-\(pending.clientRequestId.uuidString)"
        case .meal(let entry): return "meal-\(entry.id.uuidString)"
        case .activity(let activity): return "act-\(activity.id.uuidString)"
        case .checkIn(let checkIn): return "chk-\(checkIn.id.uuidString)"
        case .typing: return "typing"
        }
    }

    /// When the item happened, for ordering and timestamp gaps.
    var date: Date {
        switch self {
        case .message(let message): return message.deliverAt
        case .pending(let pending): return pending.createdAt
        case .meal(let entry): return entry.createdAt
        case .activity(let activity): return activity.occurredAt
        case .checkIn(let checkIn): return checkIn.photoCapturedAt ?? checkIn.createdAt
        case .typing(_, let at): return at
        }
    }

    var side: ThreadSide {
        switch self {
        case .message(let message):
            switch message.role {
            case .coach: return .coach
            case .user: return .me
            case .systemEvent: return .center
            }
        case .pending, .meal, .activity, .checkIn: return .me
        case .typing: return .coach
        }
    }

    /// Ties at the same instant: Luke's side first (the thing he did), then
    /// the coach's answer to it.
    fileprivate var tieRank: Int {
        switch side {
        case .me: return 0
        case .center: return 1
        case .coach: return 2
        }
    }

    /// Plain text bubbles get iMessage corner shaping; cards keep their own.
    var isBubble: Bool {
        switch self {
        case .pending, .typing: return true
        case .message(let message): return !message.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .meal, .activity, .checkIn: return false
        }
    }
}

struct DayThreadRow: Identifiable, Equatable {
    let item: DayThreadItem
    /// Non-nil: a centered timestamp goes above this row (≥15 min since the
    /// previous row, or the first row of the day).
    var timestamp: Date?
    /// Corner shaping within the same-sender group.
    var position: BubblePosition
    /// The coach avatar sits on the last row of a coach group only.
    var showsAvatar: Bool
    /// Extra breathing room above the first row of a group.
    var startsGroup: Bool

    var id: String { item.id }
}

enum DayThreadPolicy {
    /// A centered timestamp separates rows this far apart (iMessage style).
    static let timestampGap: TimeInterval = 15 * 60

    /// Every source merged into one chronological list. Rows hidden by the
    /// caller (meals pending an undoable delete) are passed in `hiddenIds`.
    static func merge(
        messages: [CoachMessage],
        pending: [CoachPendingSend],
        entries: [Entry],
        activities: [Activity],
        checkIn: WeightCheckIn?,
        typing: CoachTypingState?,
        now: Date,
        hiddenIds: Set<String> = []
    ) -> [DayThreadItem] {
        var items: [DayThreadItem] = []
        items += messages.filter { $0.status != .superseded }.map(DayThreadItem.message)
        let acceptedRequests = Set(messages.compactMap { $0.role == .user ? $0.clientRequestId : nil })
        items += pending.filter { !acceptedRequests.contains($0.clientRequestId) }.map(DayThreadItem.pending)
        items += entries.map(DayThreadItem.meal)
        items += activities.map(DayThreadItem.activity)
        if let checkIn, checkIn.hasPhoto || checkIn.hasWeight {
            items.append(.checkIn(checkIn))
        }
        items.removeAll { hiddenIds.contains($0.id) }
        var sorted = items.sorted(by: precedes)
        // A turn that is still "thinking" shows the typing bubble after
        // everything else; while text streams the bubble itself is live.
        if case .thinking(let label)? = typing {
            let last = sorted.last?.date ?? now
            sorted.append(.typing(label: label, at: max(now, last)))
        }
        return sorted
    }

    static func precedes(_ lhs: DayThreadItem, _ rhs: DayThreadItem) -> Bool {
        if lhs.date != rhs.date { return lhs.date < rhs.date }
        if lhs.tieRank != rhs.tieRank { return lhs.tieRank < rhs.tieRank }
        return lhs.id < rhs.id
    }

    /// Groups consecutive same-sender rows (broken by a timestamp or a
    /// center pill) and places timestamps on ≥15-minute gaps.
    static func rows(for items: [DayThreadItem]) -> [DayThreadRow] {
        guard !items.isEmpty else { return [] }
        var rows: [DayThreadRow] = []
        rows.reserveCapacity(items.count)
        var previous: DayThreadItem?
        for item in items {
            var timestamp: Date?
            if let previous {
                if item.date.timeIntervalSince(previous.date) >= timestampGap { timestamp = item.date }
            } else {
                timestamp = item.date
            }
            // The typing bubble never earns its own timestamp.
            if case .typing = item, previous != nil { timestamp = nil }
            let continues = previous.map { $0.side == item.side && item.side != .center } ?? false
            rows.append(DayThreadRow(
                item: item,
                timestamp: timestamp,
                position: .single,
                showsAvatar: false,
                startsGroup: !(continues && timestamp == nil)
            ))
            previous = item
        }
        // Resolve positions group by group.
        var start = 0
        while start < rows.count {
            var end = start
            while end + 1 < rows.count, !rows[end + 1].startsGroup { end += 1 }
            let count = end - start + 1
            for index in start...end {
                let offset = index - start
                rows[index].position =
                    count == 1 ? .single : offset == 0 ? .first : offset == count - 1 ? .last : .middle
                rows[index].showsAvatar = rows[index].item.side == .coach && index == end
            }
            start = end + 1
        }
        return rows
    }

    /// "Read 3:31 PM" under Luke's latest text once Shudo has it (the
    /// server accepted the turn); nil while sending or when the latest
    /// thing on his side isn't a text.
    static func readReceipt(for rows: [DayThreadRow]) -> (rowId: String, readAt: Date)? {
        guard let index = rows.lastIndex(where: { $0.item.side == .me }) else { return nil }
        guard case .message(let message) = rows[index].item, message.role == .user else { return nil }
        let reply = rows[(index + 1)...].first { $0.item.side == .coach }
        switch reply?.item {
        case .message(let coach)?: return (rows[index].id, max(message.createdAt, min(coach.deliverAt, coach.createdAt)))
        default: return (rows[index].id, message.createdAt)
        }
    }

    /// The day's coach message the deep link points at, as a row id.
    static func rowId(forMessage id: UUID) -> String { "msg-\(id.uuidString)" }
}

// MARK: - Day header math

struct DayHeaderNumbers: Equatable {
    var eatenKcal: Int
    var targetKcal: Int
    /// kcal still to eat (0 once the target is met).
    var remainingKcal: Int
    /// kcal past the target (0 until it is passed).
    var overKcal: Int
    var kcalProgress: Double
    var proteinProgress: Double
    var carbsProgress: Double
    var fatProgress: Double

    var isOver: Bool { overKcal > 0 }
}

enum DayHeaderMath {
    static func numbers(totals: DayTotals, target: MacroTarget) -> DayHeaderNumbers {
        let eaten = safe(totals.caloriesKcal)
        let goal = safe(target.caloriesKcal)
        let eatenRounded = Int(eaten.rounded())
        let goalRounded = Int(goal.rounded())
        return DayHeaderNumbers(
            eatenKcal: eatenRounded,
            targetKcal: goalRounded,
            remainingKcal: max(0, goalRounded - eatenRounded),
            overKcal: max(0, eatenRounded - goalRounded),
            kcalProgress: progress(eaten, goal),
            proteinProgress: progress(totals.proteinG, target.proteinG),
            carbsProgress: progress(totals.carbsG, target.carbsG),
            fatProgress: progress(totals.fatG, target.fatG)
        )
    }

    /// Progress toward a goal, 0…1 (rings and bars never overdraw; a met
    /// target glows instead).
    static func progress(_ value: Double, _ goal: Double) -> Double {
        guard value.isFinite, goal.isFinite, goal > 0 else { return 0 }
        return min(max(value / goal, 0), 1)
    }

    /// Day totals with meals pending an undoable delete taken out, so the
    /// header moves the moment Luke swipes, not four seconds later. Only
    /// analyzed meals count toward totals in the first place.
    static func totals(_ totals: DayTotals, excluding entries: [Entry]) -> DayTotals {
        var result = totals
        for entry in entries where entry.status == .complete {
            result.caloriesKcal -= safe(entry.caloriesKcal)
            result.proteinG -= safe(entry.proteinG)
            result.carbsG -= safe(entry.carbsG)
            result.fatG -= safe(entry.fatG)
        }
        result.caloriesKcal = max(0, result.caloriesKcal)
        result.proteinG = max(0, result.proteinG)
        result.carbsG = max(0, result.carbsG)
        result.fatG = max(0, result.fatG)
        return result
    }

    private static func safe(_ value: Double) -> Double { value.isFinite ? value : 0 }
}

// MARK: - Week strip

struct WeekStripDay: Identifiable, Equatable {
    var localDay: String
    var letter: String
    var kcalProgress: Double
    var proteinProgress: Double
    var isSelected: Bool
    var isToday: Bool
    var isFuture: Bool
    var hasLog: Bool

    var id: String { localDay }
}

enum WeekStripPolicy {
    private static let letters = ["M", "T", "W", "T", "F", "S", "S"]

    /// Monday-start week containing `selectedDay`. Server day totals fill
    /// past days; the selected day uses the live header totals.
    static func days(
        selectedDay: String,
        today: String,
        totals: [DailyNutritionTotal],
        targetHistory: [DailyMacroTargetSnapshot],
        fallbackTarget: MacroTarget,
        selectedTotals: DayTotals
    ) -> [WeekStripDay] {
        guard let monday = monday(of: selectedDay) else { return [] }
        let byDay = Dictionary(totals.map { ($0.localDay, $0) }, uniquingKeysWith: { _, last in last })
        return (0..<7).compactMap { offset -> WeekStripDay? in
            guard let day = LocalDayMath.adding(offset, to: monday) else { return nil }
            let target = NutritionProgressPolicy.effectiveTarget(
                on: day,
                history: targetHistory,
                fallback: fallbackTarget
            )
            let isSelected = day == selectedDay
            let kcal: Double
            let protein: Double
            let hasLog: Bool
            if isSelected {
                kcal = selectedTotals.caloriesKcal
                protein = selectedTotals.proteinG
                hasLog = kcal > 0 || protein > 0
            } else if let total = byDay[day] {
                kcal = total.caloriesKcal
                protein = total.proteinG
                hasLog = total.entryCount > 0
            } else {
                kcal = 0
                protein = 0
                hasLog = false
            }
            return WeekStripDay(
                localDay: day,
                letter: letters[offset],
                kcalProgress: DayHeaderMath.progress(kcal, target.caloriesKcal),
                proteinProgress: DayHeaderMath.progress(protein, target.proteinG),
                isSelected: isSelected,
                isToday: day == today,
                isFuture: day > today,
                hasLog: hasLog
            )
        }
    }

    /// The Monday on or before `localDay` (ISO week).
    static func monday(of localDay: String) -> String? {
        guard let date = LocalDayMath.date(localDay) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let weekday = calendar.component(.weekday, from: date)  // 1 = Sunday
        let offset = (weekday + 5) % 7  // Monday → 0 … Sunday → 6
        return LocalDayMath.adding(-offset, to: localDay)
    }
}

// MARK: - Day label

enum DayLabelPolicy {
    /// "Day 35 of the bulk" from the goal's anchor day; nil without a start
    /// day, before it, or for maintenance.
    static func phaseDay(localDay: String, goalStartedOn: String?, goalType: NutritionGoalType) -> String? {
        guard let goalStartedOn,
              let days = LocalDayMath.days(from: goalStartedOn, to: localDay),
              days >= 0
        else { return nil }
        switch goalType {
        case .gain: return "Day \(days + 1) of the bulk"
        case .lose: return "Day \(days + 1) of the cut"
        case .maintain: return nil
        }
    }
}
