import Foundation
import Testing
@testable import shudo

/// The strings asserted here are a cross-layer contract with
/// supabase/functions/_shared/entry_processor.ts (RESEARCH_STATUS_MESSAGES)
/// and _shared/meal_research.ts (disclosure copy). The matching Deno tests pin
/// the same literals on the server side; if either side changes copy, one of
/// the two suites fails.
struct EntryResearchPresentationTests {
    @Test func researchPhaseMessagesMatchTheServerContract() {
        #expect(EntryResearchPresentation.researchingStatusMessages == [
            "Searching the web",
            "Checking nutrition sources",
            "Calculating from sources",
        ])
        #expect(EntryResearchPresentation.isResearching(statusMessage: "Searching the web"))
        #expect(EntryResearchPresentation.isResearching(statusMessage: " Checking nutrition sources "))
        #expect(!EntryResearchPresentation.isResearching(statusMessage: "Estimating your meal"))
        #expect(!EntryResearchPresentation.isResearching(statusMessage: "Estimating without online sources"))
        #expect(!EntryResearchPresentation.isResearching(statusMessage: nil))
    }

    @Test func verifiedNotesSplitIntoProseAndTappableSources() {
        let notes = "Standard portions from the menu.\n\n"
            + "Online sources: [chipotle.com](https://www.chipotle.com/nutrition), "
            + "[nutritionix.com](https://www.nutritionix.com/brand/chipotle)."
        let breakdown = EntryResearchPresentation.breakdown(notes: notes)

        guard case .verified(let sources) = breakdown.provenance else {
            Issue.record("Expected verified provenance")
            return
        }
        #expect(sources.map(\.host) == ["chipotle.com", "nutritionix.com"])
        #expect(sources.map(\.url.absoluteString) == [
            "https://www.chipotle.com/nutrition",
            "https://www.nutritionix.com/brand/chipotle",
        ])
        #expect(breakdown.displayNotes == "Standard portions from the menu.")
        #expect(breakdown.rendersInlineMarkdown)
    }

    @Test func sourcesLineWithoutProseStillPresentsAsVerified() {
        // The server emits the line alone when the model returned no prose;
        // the shipped string-contains check missed this and showed raw
        // markdown to the user.
        let breakdown = EntryResearchPresentation.breakdown(
            notes: "Online sources: [chipotle.com](https://www.chipotle.com/nutrition)."
        )

        guard case .verified(let sources) = breakdown.provenance else {
            Issue.record("Expected verified provenance")
            return
        }
        #expect(sources.count == 1)
        #expect(breakdown.displayNotes == nil)
    }

    @Test func linklessVerifiedDisclosureMapsToVerifiedWithoutSources() {
        let breakdown = EntryResearchPresentation.breakdown(
            notes: "Portions follow the posted menu.\n\nChecked against online sources."
        )
        #expect(breakdown.provenance == .verified(sources: []))
        #expect(breakdown.displayNotes == "Portions follow the posted menu.")
        #expect(breakdown.rendersInlineMarkdown)
    }

    @Test func emptySearchDisclosureMapsToUnverifiedEstimate() {
        let notes = "Portion assumed from the photo.\n\n"
            + "No authoritative online nutrition source was found, so unverified values are clearly treated as estimates."
        let breakdown = EntryResearchPresentation.breakdown(notes: notes)
        #expect(breakdown.provenance == .unverified)
        #expect(breakdown.displayNotes == "Portion assumed from the photo.")
        #expect(!breakdown.rendersInlineMarkdown)
    }

    @Test func failedLookupDisclosureMapsToUnavailableEstimate() {
        let notes =
            "Online lookup was unavailable, so these nutrition values are estimates rather than verified restaurant facts."
        let breakdown = EntryResearchPresentation.breakdown(notes: notes)
        #expect(breakdown.provenance == .unavailable)
        #expect(breakdown.displayNotes == nil)
    }

    @Test func ordinaryNotesPassThroughUntouched() {
        let notes = "Sauce and cooking oil create most of the uncertainty.\n\nSecond paragraph."
        let breakdown = EntryResearchPresentation.breakdown(notes: notes)
        #expect(breakdown.provenance == .none)
        #expect(breakdown.displayNotes == notes)
        #expect(!breakdown.rendersInlineMarkdown)

        let empty = EntryResearchPresentation.breakdown(notes: "   ")
        #expect(empty.provenance == .none)
        #expect(empty.displayNotes == nil)

        let missing = EntryResearchPresentation.breakdown(notes: nil)
        #expect(missing.provenance == .none)
        #expect(missing.displayNotes == nil)
    }

    @Test func multiParagraphProseSurvivesSourceStripping() {
        let notes = "First paragraph.\n\nSecond paragraph.\n\n"
            + "Online sources: [a.example](https://a.example/menu)."
        let breakdown = EntryResearchPresentation.breakdown(notes: notes)
        #expect(breakdown.displayNotes == "First paragraph.\n\nSecond paragraph.")
        guard case .verified(let sources) = breakdown.provenance else {
            Issue.record("Expected verified provenance")
            return
        }
        #expect(sources.count == 1)
    }

    @Test func sourceParsingRejectsUnsafeSchemesDuplicatesAndMalformedTails() {
        let notes = "Online sources: [ok.example](https://ok.example/a), "
            + "[bad.example](javascript:alert1), "
            + "[ok.example](https://ok.example/a), "
            + "[broken.example](https://broken.exam"
        let breakdown = EntryResearchPresentation.breakdown(notes: notes)
        guard case .verified(let sources) = breakdown.provenance else {
            Issue.record("Expected verified provenance")
            return
        }
        #expect(sources.map(\.host) == ["ok.example"])
        #expect(sources.map(\.url.absoluteString) == ["https://ok.example/a"])
    }

    @Test func verifiedResearchFlagDrivesTheListRowTrace() {
        #expect(EntryResearchPresentation.hasVerifiedResearch(
            notes: "Online sources: [a.example](https://a.example/n)."
        ))
        #expect(EntryResearchPresentation.hasVerifiedResearch(
            notes: "Checked against online sources."
        ))
        #expect(!EntryResearchPresentation.hasVerifiedResearch(
            notes: "No authoritative online nutrition source was found, so unverified values are clearly treated as estimates."
        ))
        #expect(!EntryResearchPresentation.hasVerifiedResearch(notes: nil))
        #expect(!EntryResearchPresentation.hasVerifiedResearch(
            notes: "Plain estimation notes."
        ))
    }

    @Test func entryParsingCarriesAnalysisNotesForCompletedMeals() throws {
        let payload: [String: Any] = [
            "id": "11111111-1111-4111-8111-111111111111",
            "status": "complete",
            "title": "Chipotle bowl",
            "protein_g": 54,
            "carbs_g": 88,
            "fat_g": 24,
            "calories_kcal": 800,
            "processing_attempts": 1,
            "analysis_notes": "Online sources: [chipotle.com](https://www.chipotle.com/nutrition).",
        ]
        let snapshotColumns = SupabaseService.entryListColumns
            .components(separatedBy: ",")
        #expect(snapshotColumns.contains("analysis_notes"))

        let parsed = try #require(SupabaseService().parseEntry(payload))
        #expect(parsed.entry.analysisNotes?.contains("chipotle.com") == true)
        #expect(EntryResearchPresentation.hasVerifiedResearch(notes: parsed.entry.analysisNotes))
    }
}
