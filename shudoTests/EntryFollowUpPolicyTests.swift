import Foundation
import Testing
@testable import shudo

struct ClarificationPolicyTests {
    @Test func liftsTheEstimatorsQuestionFromItsNotes() {
        let notes = "Assumed 1 cup of cooked jasmine rice (approx. 186 g). Was that rice weight cooked or dry?"
        #expect(ClarificationPolicy.question(in: notes) == "Was that rice weight cooked or dry?")
    }

    @Test func returnsTheFirstQuestionWhenThereAreSeveral() {
        let notes = "Was the chicken skin-on? Did you add oil to the pan? Assumed no oil."
        #expect(ClarificationPolicy.question(in: notes) == "Was the chicken skin-on?")
    }

    @Test func notesWithoutAQuestionHaveNone() {
        #expect(ClarificationPolicy.question(in: nil) == nil)
        #expect(ClarificationPolicy.question(in: "") == nil)
        #expect(ClarificationPolicy.question(in: "Assumed 2 large eggs scrambled in 1 tsp butter.") == nil)
        #expect(ClarificationPolicy.question(in: "Estimated from the photo. 1.5 cups rice.") == nil)
    }

    @Test func ignoresTheOnlineSourcesDisclosureAndItsQueryStrings() {
        let notes = """
            Matched the regular burrito bowl.

            Source matches and portions may differ from your meal.

            Online sources: [chipotle.com](https://www.chipotle.com/nutrition?item=bowl&size=regular?), [nutritionix.com](https://nutritionix.com/q?x=1).
            """
        #expect(ClarificationPolicy.question(in: notes) == nil)

        let withQuestion = """
            Assumed white rice. Did the bowl include sour cream?

            Online sources: [chipotle.com](https://www.chipotle.com/menu?x=1).
            """
        #expect(ClarificationPolicy.question(in: withQuestion) == "Did the bowl include sour cream?")
    }

    @Test func undoesTheServersMarkdownEscapingOnVerifiedNotes() {
        let notes = #"Used the 12 oz size. Was that the \*grande\* or the venti\_iced size?"#
        #expect(ClarificationPolicy.question(in: notes) == "Was that the *grande* or the venti_iced size?")
    }

    @Test func overlongQuestionsAreSkipped() {
        let longQuestion = "Was " + String(repeating: "that very large bowl of ", count: 8) + "rice cooked?"
        #expect(longQuestion.count > ClarificationPolicy.maximumLength)
        #expect(ClarificationPolicy.question(in: "Assumed cooked. \(longQuestion)") == nil)

        // A usable later question still surfaces.
        let notes = "\(longQuestion) Was the rice weighed cooked or dry?"
        #expect(ClarificationPolicy.question(in: notes) == "Was the rice weighed cooked or dry?")

        let atLimit = "Was it " + String(repeating: "a", count: ClarificationPolicy.maximumLength - 8) + "?"
        #expect(atLimit.count == ClarificationPolicy.maximumLength)
        #expect(ClarificationPolicy.question(in: atLimit) == atLimit)
    }

    @Test func abbreviationsAndDecimalsStayInsideTheirSentence() {
        let notes = "Assumed approx. 200 g chicken, e.g. thigh. Was it 6.5 oz. or 8 oz. raw?"
        #expect(ClarificationPolicy.question(in: notes) == "Was it 6.5 oz. or 8 oz. raw?")
    }

    @Test func dropsLabelsBulletsQuotesAndStrayFragments() {
        #expect(
            ClarificationPolicy.question(in: "Assumed whole milk.\nFollow-up: Was the latte made with oat milk?")
                == "Was the latte made with oat milk?"
        )
        #expect(
            ClarificationPolicy.question(in: "- Assumed one scoop.\n- Did you use two scoops of whey?")
                == "Did you use two scoops of whey?"
        )
        #expect(
            ClarificationPolicy.question(in: "Assumed a medium apple. “Was it a large one?”")
                == "Was it a large one?"
        )
        #expect(
            ClarificationPolicy.question(in: "Assumed grilled (was it fried in oil?)")
                == nil
        )
        // Too short to be a real follow-up.
        #expect(ClarificationPolicy.question(in: "Assumed 2% milk. Why? Unknown.") == nil)
    }

    @Test func neverLiftsALink() {
        #expect(ClarificationPolicy.question(in: "See https://example.com/item?") == nil)
        #expect(ClarificationPolicy.question(in: "Matched [menu](https://x.com/a?b) item?") == nil)
    }

    @Test func answerPrefillAndUntouchedPrefillCountsAsEmpty() {
        let prefill = ClarificationPolicy.answerPrefill(for: "Was that rice weight cooked or dry?")
        #expect(prefill == "Q: Was that rice weight cooked or dry? A: ")
        #expect(ClarificationPolicy.submittableText(prefill, prefill: prefill) == "")
        #expect(ClarificationPolicy.submittableText("Q: Was that rice weight cooked or dry? A:", prefill: prefill) == "")
        #expect(
            ClarificationPolicy.submittableText(prefill + "Cooked.", prefill: prefill)
                == "Q: Was that rice weight cooked or dry? A: Cooked."
        )
        // Without a prefill the note passes through untouched.
        #expect(ClarificationPolicy.submittableText("  ", prefill: "") == "  ")
        #expect(ClarificationPolicy.submittableText("One cup.", prefill: "") == "One cup.")
    }

    @Test func dictatedAnswersAppendRightAfterThePrefill() {
        let prefill = ClarificationPolicy.answerPrefill(for: "Was that rice weight cooked or dry?")
        let merged = DictationMergePolicy.appending("Cooked.", to: prefill, limit: EntryCorrectionPolicy.maximumCharacters)
        #expect(merged.note == "Q: Was that rice weight cooked or dry? A: Cooked.")
    }
}

struct LogAgainPolicyTests {
    private func item(_ name: String, _ amount: String) -> SupabaseService.EntryDetailItem {
        SupabaseService.EntryDetailItem(
            name: name, amount: amount, proteinG: 0, carbsG: 0, fatG: 0, caloriesKcal: 0
        )
    }

    @Test func titleThenWhatWasSaid() {
        #expect(
            LogAgainPolicy.text(
                title: "Eggs, rice and fruit",
                rawText: "3 scrambled eggs, 200 g cooked jasmine rice and a banana",
                transcript: nil
            ) == "Eggs, rice and fruit: 3 scrambled eggs, 200 g cooked jasmine rice and a banana"
        )
    }

    @Test func aLegacyVoiceMealUsesItsTranscript() {
        #expect(
            LogAgainPolicy.text(title: "Protein shake", rawText: "  ", transcript: "Two scoops of whey with whole milk")
                == "Protein shake: Two scoops of whey with whole milk"
        )
        // A typed note plus a transcript keeps both, once each.
        #expect(
            LogAgainPolicy.text(title: "Pizza", rawText: "extra cheese", transcript: "Two slices of pepperoni")
                == "Pizza: extra cheese\nTwo slices of pepperoni"
        )
        #expect(
            LogAgainPolicy.text(title: "Shake", rawText: "Whey shake", transcript: "whey shake")
                == "Shake: Whey shake"
        )
    }

    @Test func noRepeatedTitleWhenTheDescriptionAlreadyStartsWithIt() {
        #expect(
            LogAgainPolicy.text(title: "Greek yogurt", rawText: "greek yogurt with honey", transcript: nil)
                == "greek yogurt with honey"
        )
    }

    @Test func aPhotoOnlyMealFallsBackToItsItemBreakdown() {
        let text = LogAgainPolicy.text(
            title: "Chicken and rice",
            rawText: nil,
            transcript: nil,
            items: [item("Grilled chicken breast", "6 oz"), item("White rice, cooked", "1 cup"), item("Salsa", " ")]
        )
        #expect(text == "Chicken and rice: Grilled chicken breast (6 oz); White rice, cooked (1 cup); Salsa")
    }

    @Test func titleAloneWhenNothingElseIsKnownAndNilWhenEmpty() {
        #expect(LogAgainPolicy.text(title: "  Bagel   with lox ", rawText: nil, transcript: nil) == "Bagel with lox")
        #expect(LogAgainPolicy.text(title: " ", rawText: nil, transcript: nil) == nil)
        #expect(LogAgainPolicy.text(title: "", rawText: "Oatmeal", transcript: nil) == "Oatmeal")
    }

    @Test func staysWithinTheComposerLimit() {
        let long = String(repeating: "rice ", count: 4_000)
        let text = LogAgainPolicy.text(title: "Rice", rawText: long, transcript: nil)
        #expect((text?.utf16.count ?? 0) <= EntryComposerPolicy.maximumNoteLength)
    }

    @Test func readsTheDetailModel() {
        let detail = SupabaseService.EntryDetail(
            createdAt: Date(),
            imageURL: nil,
            additionalPhotos: [],
            title: "Overnight oats",
            rawText: "Overnight oats with a scoop of whey",
            transcript: nil,
            proteinG: 40,
            carbsG: 60,
            fatG: 10,
            caloriesKcal: 490,
            items: [item("Oats", "1/2 cup")],
            analysisNotes: nil,
            confidence: 0.8
        )
        #expect(LogAgainPolicy.text(for: detail) == "Overnight oats with a scoop of whey")
    }
}
