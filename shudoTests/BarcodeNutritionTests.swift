import Foundation
import Testing
@testable import shudo

struct BarcodeNutritionTests {
    @Test func scannerPayloadsNormalizeToLookupCodes() {
        // EAN-13 passes through; US UPC-A is zero-padded the way
        // Open Food Facts stores it; EAN-8 stays as-is.
        #expect(BarcodeNutrition.normalizedGTIN(from: "5449000000996") == "5449000000996")
        #expect(BarcodeNutrition.normalizedGTIN(from: "016000275270") == "0016000275270")
        #expect(BarcodeNutrition.normalizedGTIN(from: "96385074") == "96385074")
        #expect(BarcodeNutrition.normalizedGTIN(from: " 5449000000996 ") == "5449000000996")

        // GTIN-14 case codes resolve to the retail code only when the
        // packaging indicator is zero.
        #expect(BarcodeNutrition.normalizedGTIN(from: "05449000000996") == "5449000000996")
        #expect(BarcodeNutrition.normalizedGTIN(from: "15449000000996") == nil)

        // GS1 Digital Link QR codes carry the GTIN behind the /01/ segment.
        #expect(
            BarcodeNutrition.normalizedGTIN(
                from: "https://id.gs1.org/01/05449000000996/10/LOT42"
            ) == "5449000000996"
        )
        #expect(
            BarcodeNutrition.normalizedGTIN(from: "https://example.com/promo") == nil
        )

        #expect(BarcodeNutrition.normalizedGTIN(from: "") == nil)
        #expect(BarcodeNutrition.normalizedGTIN(from: "not-a-code") == nil)
        #expect(BarcodeNutrition.normalizedGTIN(from: "12345") == nil)
    }

    private func productJSON(
        nutriments: [String: Any],
        name: String = "Honey Nut Cheerios",
        servingSize: String? = "3/4 cup (28 g)"
    ) -> [String: Any] {
        var product: [String: Any] = [
            "product_name": name,
            "brands": "General Mills",
            "nutriments": nutriments
        ]
        if let servingSize { product["serving_size"] = servingSize }
        return ["status": 1, "code": "0016000275270", "product": product]
    }

    @Test func openFoodFactsProductParsesServingAndPer100gMacros() throws {
        let parsed = try #require(BarcodeNutrition.product(fromOpenFoodFacts: productJSON(
            nutriments: [
                "energy-kcal_serving": 110,
                "proteins_serving": 2,
                "carbohydrates_serving": 22.0,
                "fat_serving": "1.5",
                "energy-kcal_100g": 393,
                "proteins_100g": 7.14,
                "carbohydrates_100g": 78.57,
                "fat_100g": 5.36
            ]
        )))

        #expect(parsed.name == "Honey Nut Cheerios")
        #expect(parsed.brands == "General Mills")
        #expect(parsed.servingSize == "3/4 cup (28 g)")
        #expect(parsed.perServing?.caloriesKcal == 110)
        #expect(parsed.perServing?.fatG == 1.5)
        #expect(parsed.per100g?.proteinG == 7.14)
    }

    @Test func junkLabelNumbersAreRejectedNotPropagated() {
        // Negative, non-finite, and absurd values never reach the composer.
        #expect(BarcodeNutrition.product(fromOpenFoodFacts: productJSON(
            nutriments: [
                "energy-kcal_100g": -5,
                "proteins_100g": Double.infinity,
                "carbohydrates_100g": 4_000,
                "fat_100g": "garbage"
            ]
        )) == nil)

        // A miss or nameless product is a miss, not a crash.
        #expect(BarcodeNutrition.product(fromOpenFoodFacts: [
            "status": 0, "status_verbose": "product not found"
        ]) == nil)
        #expect(BarcodeNutrition.product(fromOpenFoodFacts: productJSON(
            nutriments: ["energy-kcal_100g": 100],
            name: "  "
        )) == nil)
    }

    @Test func feedTextIsMadePresentable() {
        // Duplicated gram parentheticals collapse; distinct ones survive.
        #expect(
            BarcodeNutrition.sanitizedServingSize("3/4 cup (28 g) (28 g)")
                == "3/4 cup (28 g)"
        )
        #expect(
            BarcodeNutrition.sanitizedServingSize("2 cookies (30 g) (about 1 oz)")
                == "2 cookies (30 g) (about 1 oz)"
        )
        #expect(BarcodeNutrition.sanitizedServingSize("  1 bar (60 g)  ") == "1 bar (60 g)")

        // ALL-CAPS feed names calm down; mixed case is preserved verbatim.
        #expect(BarcodeNutrition.displayName("QUEST PROTEIN BAR") == "Quest Protein Bar")
        #expect(
            BarcodeNutrition.displayName("Gmills hny nut cheerios")
                == "Gmills hny nut cheerios"
        )
    }

    @Test func portionsScaleLabelMacrosByChosenAmount() throws {
        let product = try #require(BarcodeNutrition.product(fromOpenFoodFacts: productJSON(
            nutriments: [
                "energy-kcal_serving": 110,
                "proteins_serving": 2,
                "carbohydrates_serving": 22,
                "fat_serving": 1.5
            ]
        )))
        var portion = ScannedPortion(product: product)
        #expect(portion.quantityLabel == "1 serving")
        #expect(portion.scaledMacros?.caloriesKcal == 110)

        portion.quantity = 2.5
        #expect(portion.quantityLabel == "2.5 servings")
        #expect(portion.scaledMacros?.caloriesKcal == 275)
        #expect(portion.scaledMacros?.proteinG == 5)
        #expect(portion.scaledMacros?.fatG == 3.75)

        // Per-100g labels count in grams instead of servings.
        let bulk = try #require(BarcodeNutrition.product(fromOpenFoodFacts: productJSON(
            nutriments: ["energy-kcal_100g": 393, "proteins_100g": 7.14],
            servingSize: nil
        )))
        var bulkPortion = ScannedPortion(product: bulk)
        bulkPortion.quantity = 1.5
        #expect(bulkPortion.quantityLabel == "150 g")
        #expect(bulkPortion.scaledMacros?.caloriesKcal == 589.5)
    }

    @Test func submissionTextQuotesLabelsAndStatesEatenTotals() throws {
        let product = try #require(BarcodeNutrition.product(fromOpenFoodFacts: productJSON(
            nutriments: [
                "energy-kcal_serving": 110,
                "proteins_serving": 2,
                "carbohydrates_serving": 22,
                "fat_serving": 1.5
            ]
        )))
        var portion = ScannedPortion(product: product)
        portion.quantity = 2

        let text = BarcodeNutrition.submissionText(for: [portion])
        // First line reads like a meal title for the optimistic row.
        #expect(text.hasPrefix("Honey Nut Cheerios (General Mills) — 2 servings."))
        #expect(text.contains(
            "Scanned nutrition label per serving (3/4 cup (28 g)): 110 kcal, 2 g protein, 22 g carbs, 1.5 g fat."
        ))
        #expect(text.contains("Eaten amount works out to 220 kcal, 4 g protein, 44 g carbs, 3 g fat."))

        // Quantity of exactly one skips the redundant totals line, and a
        // name that already includes the brand is not doubled.
        let branded = try #require(BarcodeNutrition.product(fromOpenFoodFacts: productJSON(
            nutriments: ["energy-kcal_serving": 110],
            name: "General Mills Honey Nut Cheerios"
        )))
        let single = BarcodeNutrition.submissionText(for: [ScannedPortion(product: branded)])
        #expect(!single.contains("Eaten amount"))
        #expect(!single.contains("(General Mills)"))

        // Multiple scans serialize as separate blocks; none is empty.
        let both = BarcodeNutrition.submissionText(for: [portion, ScannedPortion(product: branded)])
        #expect(both.components(separatedBy: "\n\n").count == 2)
        #expect(BarcodeNutrition.submissionText(for: []) == "")
    }
}
