import Foundation

/// Deterministic copy for the thread's rich cards (pure; unit-tested). The
/// coach writes the words in bubbles; numbers on cards are formatted here
/// from the card payloads the server computed.
enum ThreadCardCopy {
    // MARK: Game plan

    /// An icon for a game-plan line, from its words.
    static func planSymbol(for action: String) -> String {
        let tokens = words(in: action)
        func has(_ prefixes: [String]) -> Bool {
            tokens.contains { token in prefixes.contains { token.hasPrefix($0) } }
        }
        if has(["sleep", "bed", "lights", "wind"]) { return "moon.zzz.fill" }
        if has(["protein", "grams"]) { return "bolt.fill" }
        if has(["lift", "upper", "lower", "push", "pull", "legs", "squat", "bench", "deadlift", "session", "gym", "train"]) {
            return "dumbbell.fill"
        }
        if has(["bike", "cardio", "run", "row", "conditioning"]) { return "figure.outdoor.cycle" }
        if has(["walk", "steps"]) { return "figure.walk" }
        if has(["water", "hydrat"]) { return "drop.fill" }
        if has(["photo", "check-in", "checkin", "weigh", "scale"]) { return "camera.fill" }
        if has(["kcal", "calorie", "meal", "eat", "breakfast", "lunch", "dinner", "shake", "snack", "milk", "food"]) {
            return "fork.knife"
        }
        return "checkmark.circle.fill"
    }

    /// "Game plan · Tue" from the message's local day.
    static func planEyebrow(localDay: String) -> String {
        guard let weekday = weekdayName(localDay, short: true) else { return "Game plan" }
        return "Game plan · \(weekday)"
    }

    // MARK: Recap

    /// A day recap delivered in the morning is about yesterday ("Monday
    /// recap"); one delivered later is about that day.
    static func recapEyebrow(card: RecapCard, localDay: String, deliveredHour: Int) -> String {
        if card.period == .week { return "Weekly recap" }
        let day = deliveredHour < 11 ? (LocalDayMath.adding(-1, to: localDay) ?? localDay) : localDay
        guard let weekday = weekdayName(day, short: false) else { return "Day recap" }
        return "\(weekday) recap"
    }

    static func proteinVerdict(protein: Double, target: Double) -> String {
        guard target > 0 else { return "protein" }
        if protein >= target * 0.97 { return "protein · hit" }
        return "protein · \(Int((target - protein).rounded()))g short"
    }

    // MARK: Snack

    /// `home` / `any` refs have no store to route to.
    static func hasDirections(_ option: SnackRec.Option) -> Bool {
        let ref = option.storeRef.lowercased()
        guard ref != "home", ref != "any" else { return false }
        return !option.mapsQuery.trimmingCharacters(in: .whitespaces).isEmpty || !option.storeName.isEmpty
    }

    static func snackEyebrow(_ option: SnackRec.Option?) -> String {
        guard let option else { return "Nearby" }
        switch option.storeRef.lowercased() {
        case "home": return "Your kitchen"
        case "any": return "Any corner store"
        default:
            if option.walkMinutes <= 0 { return "Nearby" }
            if option.walkMinutes <= 2 { return "Nearby · 1 block" }
            return "Nearby · \(option.walkMinutes) min walk"
        }
    }

    /// "Core Power Elite ×2 + Chobani Complete"
    static func snackTitle(_ option: SnackRec.Option) -> String {
        option.items.map { item in
            let quantity = item.quantity.rounded()
            let suffix = quantity >= 2 ? " ×\(Int(quantity))" : ""
            return item.name + suffix
        }
        .joined(separator: " + ")
    }

    /// "7-Eleven · 4 min walk · ~$9"
    static func snackSubtitle(_ option: SnackRec.Option) -> String {
        var parts: [String] = []
        if !option.storeName.isEmpty { parts.append(option.storeName) }
        if option.walkMinutes > 0, !["home", "any"].contains(option.storeRef.lowercased()) {
            parts.append("\(option.walkMinutes) min walk")
        }
        let prices = option.items.compactMap { item in item.priceUsdEst.map { $0 * max(1, item.quantity) } }
        if !prices.isEmpty {
            parts.append("~$\(Int(prices.reduce(0, +).rounded(.up)))")
        }
        return parts.joined(separator: " · ")
    }

    /// The one-line payoff under the deltas.
    static func snackPayoff(remainingAfter: CoachMacros, beforeLift: Bool) -> String {
        if remainingAfter.proteinG <= 0.5 {
            return beforeLift ? "Protein closed before you lift." : "Protein closed for the day."
        }
        return "\(Int(remainingAfter.proteinG.rounded()))g protein still to go after this."
    }

    // MARK: Workout

    static func prValue(_ record: WorkoutAckCard.PersonalRecord) -> String {
        let value = formatted(record.value)
        switch record.kind {
        case .reps: return "\(value) reps"
        case .e1rm: return "e1RM \(value) \(record.unit)"
        case .weight: return "\(value) \(record.unit)"
        }
    }

    static func prDelta(_ record: WorkoutAckCard.PersonalRecord) -> String? {
        guard let previous = record.previous, record.value > previous else { return nil }
        return "+\(formatted(record.value - previous))"
    }

    // MARK: Goal change

    static func goalLabel(_ raw: String?) -> String? {
        switch raw?.lowercased() {
        case "gain", "lean_bulk", "bulk": return "Lean bulk"
        case "lose", "cut": return "Cut"
        case "maintain", "maintenance": return "Maintain"
        case nil: return nil
        case let other?: return other.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    // MARK: Shared

    static func formatted(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if abs(value - value.rounded()) < 0.05 { return Int(value.rounded()).formatted() }
        return String(format: "%.1f", value)
    }

    /// Lowercased word tokens (letters, digits, hyphens) for keyword matching.
    static func words(in text: String) -> [String] {
        text.lowercased()
            .split { !($0.isLetter || $0.isNumber || $0 == "-") }
            .map(String.init)
    }

    static func weekdayName(_ localDay: String, short: Bool) -> String? {
        guard let date = LocalDayMath.date(localDay) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = short ? "EEE" : "EEEE"
        return formatter.string(from: date)
    }
}

/// An icon tile for a meal receipt when there's no photo.
enum MealGlyphPolicy {
    static func symbol(for summary: String) -> String {
        let tokens = ThreadCardCopy.words(in: summary)
        func has(_ prefixes: [String]) -> Bool {
            tokens.contains { token in prefixes.contains { token.hasPrefix($0) } }
        }
        if has(["coffee", "latte", "espresso", "cappuccino"]) { return "cup.and.saucer.fill" }
        if has(["milk", "shake", "smoothie", "core", "fairlife", "chobani"]) {
            return "takeoutbag.and.cup.and.straw.fill"
        }
        if has(["egg", "oat", "toast", "pancake", "waffle", "bagel", "cereal"]) { return "sunrise.fill" }
        if has(["bowl", "chipotle", "sweetgreen", "salad", "burrito", "rice"]) { return "fork.knife" }
        if has(["steak", "chicken", "beef", "salmon", "fish", "pork", "turkey"]) { return "flame.fill" }
        if has(["banana", "apple", "berries", "fruit", "orange"]) { return "leaf.fill" }
        if has(["bar", "snack", "chips", "cookie", "jerky", "yogurt"]) { return "bag.fill" }
        return "fork.knife"
    }
}
