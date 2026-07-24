import Foundation

/// A packaged product resolved from a scanned barcode.
struct ScannedProduct: Equatable {
    struct Macros: Equatable {
        let caloriesKcal: Double?
        let proteinG: Double?
        let carbsG: Double?
        let fatG: Double?

        var hasAnyValue: Bool {
            caloriesKcal != nil || proteinG != nil || carbsG != nil || fatG != nil
        }
    }

    let barcode: String
    let name: String
    let brands: String?
    let servingSize: String?
    let perServing: Macros?
    let per100g: Macros?

    /// Display title; avoids doubling the brand when the name contains it.
    var displayTitle: String {
        guard let brands, !name.lowercased().contains(brands.lowercased()) else {
            return name
        }
        return "\(name) (\(brands))"
    }

    /// The label facts the card and submission both use: serving facts when
    /// the label has them, otherwise per-100 g.
    var referenceMacros: Macros? { perServing ?? per100g }
    var usesServingUnits: Bool { perServing != nil }
}

/// A scanned product plus the amount the user says they ate. Quantity is in
/// servings when the label has serving facts, otherwise in multiples of
/// 100 g.
struct ScannedPortion: Identifiable, Equatable {
    let id = UUID()
    var product: ScannedProduct
    var quantity: Double = 1

    static let minimumQuantity = 0.5
    static let maximumQuantity = 10.0
    static let quantityStep = 0.5

    var scaledMacros: ScannedProduct.Macros? {
        guard let reference = product.referenceMacros else { return nil }
        func scale(_ value: Double?) -> Double? {
            value.map { $0 * quantity }
        }
        return ScannedProduct.Macros(
            caloriesKcal: scale(reference.caloriesKcal),
            proteinG: scale(reference.proteinG),
            carbsG: scale(reference.carbsG),
            fatG: scale(reference.fatG)
        )
    }

    /// "1 serving", "2.5 servings", "150 g".
    var quantityLabel: String {
        if product.usesServingUnits {
            let amount = BarcodeNutrition.compactAmount(quantity)
            return quantity == 1 ? "1 serving" : "\(amount) servings"
        }
        return "\(BarcodeNutrition.compactAmount(quantity * 100)) g"
    }
}

enum BarcodeNutrition {
    /// Open Food Facts asks integrations to identify themselves.
    static let userAgent = "Shudo/1.0 (https://shudo.yng.sh)"
    static let lookupTimeout: TimeInterval = 10

    // Sanity bounds for label data: pure fat is ~900 kcal per 100 g, and a
    // single serving of anything a person logs stays far under these caps.
    private static let maximumKcalPer100g = 950.0
    private static let maximumGramsPer100g = 105.0
    private static let maximumKcalPerServing = 5_000.0
    private static let maximumGramsPerServing = 1_000.0

    /// Canonical lookup code from whatever the scanner produced: a plain
    /// EAN/UPC payload, a QR code containing a GS1 Digital Link URL, or a QR
    /// code that is just the digits.
    static func normalizedGTIN(from payload: String) -> String? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // GS1 Digital Link QR: https://id.gs1.org/01/{gtin}/... or any host
        // using the /01/{gtin} application identifier path.
        if trimmed.lowercased().hasPrefix("http"),
           let url = URL(string: trimmed) {
            let segments = url.pathComponents
            if let marker = segments.firstIndex(of: "01"),
               segments.indices.contains(marker + 1) {
                return canonicalDigits(segments[marker + 1])
            }
            return nil
        }

        return canonicalDigits(trimmed)
    }

    private static func canonicalDigits(_ value: String) -> String? {
        let digits = value.filter(\.isNumber)
        guard digits.count == value.count || value == digits else { return nil }
        switch digits.count {
        case 8, 13:
            return digits
        case 12:
            // US UPC-A: Open Food Facts stores these zero-padded to 13.
            return "0" + digits
        case 14:
            // GTIN-14 with a packaging indicator; the retail code is the
            // trailing 13 digits when the indicator is 0.
            return digits.hasPrefix("0") ? String(digits.dropFirst()) : nil
        default:
            return nil
        }
    }

    /// Parses the Open Food Facts v2 product payload. Returns nil when the
    /// product is missing or carries no usable nutrition numbers.
    static func product(fromOpenFoodFacts object: [String: Any]) -> ScannedProduct? {
        guard let status = object["status"] as? Int, status == 1,
              let product = object["product"] as? [String: Any] else { return nil }

        let name = (product["product_name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return nil }

        let nutriments = product["nutriments"] as? [String: Any] ?? [:]
        let perServing = macros(
            from: nutriments,
            suffix: "_serving",
            kcalLimit: maximumKcalPerServing,
            gramLimit: maximumGramsPerServing
        )
        let per100g = macros(
            from: nutriments,
            suffix: "_100g",
            kcalLimit: maximumKcalPer100g,
            gramLimit: maximumGramsPer100g
        )
        guard perServing?.hasAnyValue == true || per100g?.hasAnyValue == true else {
            return nil
        }

        let brands = (product["brands"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let servingSize = (product["serving_size"] as? String)
            .map(sanitizedServingSize)
        return ScannedProduct(
            barcode: (object["code"] as? String) ?? "",
            name: displayName(name),
            brands: brands?.isEmpty == false ? brands : nil,
            servingSize: servingSize?.isEmpty == false ? servingSize : nil,
            perServing: perServing,
            per100g: per100g
        )
    }

    /// Product feeds ship names in ALL CAPS often enough to look shouty on
    /// the card; anything mixed-case is left exactly as published.
    static func displayName(_ name: String) -> String {
        let letters = name.filter(\.isLetter)
        guard !letters.isEmpty, letters.allSatisfy(\.isUppercase) else { return name }
        return name.localizedCapitalized
    }

    /// Open Food Facts serving sizes frequently duplicate the gram
    /// parenthetical ("3/4 cup (28 g) (28 g)"); collapse the repeats.
    static func sanitizedServingSize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let regex = try? NSRegularExpression(
            pattern: #"(\([^()]*\))(\s*\1)+"#
        ) else { return trimmed }
        return regex.stringByReplacingMatches(
            in: trimmed,
            range: NSRange(trimmed.startIndex..., in: trimmed),
            withTemplate: "$1"
        )
    }

    private static func macros(
        from nutriments: [String: Any],
        suffix: String,
        kcalLimit: Double,
        gramLimit: Double
    ) -> ScannedProduct.Macros? {
        func value(_ key: String, limit: Double) -> Double? {
            let raw = nutriments[key + suffix]
            let number: Double?
            if let double = raw as? Double {
                number = double
            } else if let int = raw as? Int {
                number = Double(int)
            } else if let string = raw as? String {
                number = Double(string)
            } else {
                number = nil
            }
            guard let number, number.isFinite, number >= 0, number <= limit else {
                return nil
            }
            return number
        }

        let macros = ScannedProduct.Macros(
            caloriesKcal: value("energy-kcal", limit: kcalLimit),
            proteinG: value("proteins", limit: gramLimit),
            carbsG: value("carbohydrates", limit: gramLimit),
            fatG: value("fat", limit: gramLimit)
        )
        return macros.hasAnyValue ? macros : nil
    }

    /// The scanned portions as submission text appended after the user's own
    /// words. Label facts are quoted verbatim and the eaten totals are stated
    /// explicitly so the analysis model never re-estimates the product.
    static func submissionText(for portions: [ScannedPortion]) -> String {
        portions.compactMap { portion in
            guard let reference = portion.product.referenceMacros else { return nil }
            let product = portion.product

            var descriptor = product.usesServingUnits ? "per serving" : "per 100 g"
            if product.usesServingUnits, let servingSize = product.servingSize {
                descriptor = "per serving (\(servingSize))"
            }

            // The first line doubles as the optimistic row title when the
            // user adds no note of their own, so it reads like a meal name.
            var lines = [
                "\(product.displayTitle) — \(portion.quantityLabel).",
                "Scanned nutrition label \(descriptor): \(macroLine(reference)).",
            ]
            if let totals = portion.scaledMacros, portion.quantity != 1 {
                lines.append("Eaten amount works out to \(macroLine(totals)).")
            }
            return lines.joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }

    static func macroLine(_ macros: ScannedProduct.Macros) -> String {
        var parts: [String] = []
        if let kcal = macros.caloriesKcal { parts.append("\(compactAmount(kcal)) kcal") }
        if let protein = macros.proteinG { parts.append("\(compactAmount(protein)) g protein") }
        if let carbs = macros.carbsG { parts.append("\(compactAmount(carbs)) g carbs") }
        if let fat = macros.fatG { parts.append("\(compactAmount(fat)) g fat") }
        return parts.joined(separator: ", ")
    }

    static func compactAmount(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? String(Int(rounded.rounded()))
            : String(rounded)
    }
}

/// Thin network client; all parsing lives in `BarcodeNutrition` for tests.
struct OpenFoodFactsClient {
    var lookup: @Sendable (String) async throws -> ScannedProduct?

    static let live = OpenFoodFactsClient { gtin in
        var components = URLComponents(
            string: "https://world.openfoodfacts.org/api/v2/product/\(gtin).json"
        )!
        components.queryItems = [
            URLQueryItem(
                name: "fields",
                value: "product_name,brands,serving_size,nutriments"
            )
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = BarcodeNutrition.lookupTimeout
        request.setValue(BarcodeNutrition.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) || http.statusCode == 404 else {
            throw URLError(.badServerResponse)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return BarcodeNutrition.product(fromOpenFoodFacts: object)
    }
}
