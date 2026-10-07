import Foundation

/// The estimator's one follow-up question, lifted out of `analysis_notes`.
///
/// For a materially ambiguous amount the analyzer writes a single short
/// question into its notes next to the assumption it made ("Assumed cooked
/// weight. Was that rice weight cooked or dry?" — entry_processor.ts). The
/// detail screen surfaces it as a "Shudo needs one detail" row instead of
/// leaving it buried in prose. Pure and deterministic; nothing here calls a
/// model.
enum ClarificationPolicy {
    /// Longer than this is a run-on paragraph, not a short follow-up.
    static let maximumLength = 160

    /// The first usable question sentence in the model's prose, or nil.
    /// The server-owned research disclosure ("Online sources: …" and
    /// anything after it) is ignored — its links may carry `?` in query
    /// strings and it never asks Luke anything.
    static func question(in notes: String?) -> String? {
        guard let notes else { return nil }
        for sentence in sentences(in: modelProse(notes)) {
            let candidate = cleaned(sentence)
            guard candidate.hasSuffix("?"), isUsable(candidate) else { continue }
            return candidate
        }
        return nil
    }

    /// What the correction note starts with when Luke taps "Answer": the
    /// question for the estimator's context, then room for his reply.
    static func answerPrefill(for question: String) -> String {
        "Q: \(question) A: "
    }

    /// The note as it should be submitted: an untouched prefill (no answer
    /// typed or dictated after "A:") counts as empty, so the sheet never
    /// sends a bare question back to the estimator.
    static func submittableText(_ note: String, prefill: String) -> String {
        let trimmedPrefill = prefill.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrefill.isEmpty,
              note.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedPrefill
        else { return note }
        return ""
    }

    // MARK: Internals

    /// Model prose only: everything before a line that starts the
    /// server's "Online sources:" block (same split as meal_research.ts).
    static func modelProse(_ notes: String) -> String {
        let lines = notes.components(separatedBy: .newlines)
        var kept: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.range(of: "Online sources:", options: [.caseInsensitive, .anchored]) != nil {
                break
            }
            kept.append(line)
        }
        return kept.joined(separator: "\n")
    }

    /// Splits prose into sentences. Line breaks always end one; `?` and `!`
    /// end one before whitespace; `.` ends one only when the next word
    /// doesn't start lowercase or with a digit, so "approx. 200 g" and
    /// "e.g. jasmine" stay inside their sentence.
    static func sentences(in prose: String) -> [String] {
        let characters = Array(prose)
        var sentences: [String] = []
        var current = ""

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { sentences.append(trimmed) }
            current = ""
        }

        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character.isNewline {
                flush()
                index += 1
                continue
            }
            current.append(character)
            index += 1
            guard character == "?" || character == "!" || character == "." else { continue }

            // Closing quotes/brackets stay with the sentence they close.
            while index < characters.count, closers.contains(characters[index]) {
                current.append(characters[index])
                index += 1
            }
            guard index < characters.count else { break }
            guard characters[index].isWhitespace else { continue }

            if character == "." {
                var lookahead = index
                while lookahead < characters.count, characters[lookahead].isWhitespace,
                      !characters[lookahead].isNewline {
                    lookahead += 1
                }
                if lookahead < characters.count {
                    let next = characters[lookahead]
                    if next.isLowercase || next.isNumber { continue }
                }
            }
            flush()
        }
        flush()
        return sentences
    }

    private static let closers: Set<Character> = ["\"", "”", "’", "'", ")", "]"]
    private static let wrappingQuotes = CharacterSet(charactersIn: "\"“”‘’'")

    /// Undo the server's markdown escaping (verified meals), drop bullets,
    /// a "Follow-up:" style label, wrapping quotes or parentheses, and
    /// collapse whitespace.
    private static func cleaned(_ sentence: String) -> String {
        var text = sentence.replacingOccurrences(
            of: #"\\([\\`*_\[\]<>])"#,
            with: "$1",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"^\s*(?:[-•*]|\d+[.)])\s+"#,
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"^\s*(?:follow[- ]?up(?: question)?|question|clarification|q)\s*:\s*"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.trimmingCharacters(in: wrappingQuotes.union(.whitespaces))
        if text.hasPrefix("("), text.hasSuffix(")") {
            text = String(text.dropFirst().dropLast())
        }
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespaces)
    }

    private static func isUsable(_ question: String) -> Bool {
        guard question.count <= maximumLength else { return false }
        // A real question has a few words; a lone "Why?" or "2%?" isn't one.
        let words = question.split(whereSeparator: \.isWhitespace)
        guard words.count >= 3 else { return false }
        // Never lift raw links (their query strings end in "?").
        let lowered = question.lowercased()
        return !lowered.contains("http://") && !lowered.contains("https://")
            && !lowered.contains("](") && !lowered.contains("www.")
    }
}

/// The text "Log again" re-submits for today: the meal's title plus what was
/// originally said or typed, falling back to the item breakdown for a
/// photo-only meal. Goes through the normal capture path, so the server
/// re-estimates it like any other text meal.
enum LogAgainPolicy {
    static func text(for detail: SupabaseService.EntryDetail) -> String? {
        text(
            title: detail.title,
            rawText: detail.rawText,
            transcript: detail.transcript,
            items: detail.items
        )
    }

    static func text(
        title: String,
        rawText: String?,
        transcript: String?,
        items: [SupabaseService.EntryDetailItem] = []
    ) -> String? {
        let cleanTitle = collapsed(title)
        var parts: [String] = []
        for candidate in [rawText, transcript] {
            guard let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty,
                  !parts.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame })
            else { continue }
            parts.append(value)
        }
        if parts.isEmpty {
            let breakdown = items.compactMap(itemLine).joined(separator: "; ")
            if !breakdown.isEmpty { parts.append(breakdown) }
        }

        let description = parts.joined(separator: "\n")
        let combined: String
        if description.isEmpty {
            combined = cleanTitle
        } else if cleanTitle.isEmpty
                    || description.range(
                        of: cleanTitle,
                        options: [.caseInsensitive, .diacriticInsensitive, .anchored]
                    ) != nil {
            combined = description
        } else {
            combined = "\(cleanTitle): \(description)"
        }
        guard !combined.isEmpty else { return nil }
        return EntryComposerPolicy.boundedNote(combined)
    }

    private static func itemLine(_ item: SupabaseService.EntryDetailItem) -> String? {
        let name = collapsed(item.name)
        guard !name.isEmpty else { return nil }
        let amount = collapsed(item.amount)
        return amount.isEmpty ? name : "\(name) (\(amount))"
    }

    private static func collapsed(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
