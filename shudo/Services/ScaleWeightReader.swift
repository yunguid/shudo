import Foundation
import UIKit
import Vision

enum ScaleWeightReader {
    struct Candidate: Sendable {
        let text: String
        let confidence: Float
        let area: Double
    }

    static func recognizedDisplayedWeight(in image: UIImage, units: String) async -> Double? {
        guard let cgImage = image.cgImage else { return nil }
        return await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.minimumTextHeight = 0.04
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                return nil
            }
            let candidates = (request.results ?? []).compactMap { observation -> Candidate? in
                guard let top = observation.topCandidates(1).first else { return nil }
                return Candidate(
                    text: top.string,
                    confidence: top.confidence,
                    area: observation.boundingBox.width * observation.boundingBox.height
                )
            }
            return bestDisplayedWeight(from: candidates, units: units)
        }.value
    }

    static func bestDisplayedWeight(from candidates: [Candidate], units: String) -> Double? {
        let imperial = units.lowercased() == "imperial"
        let displayedRange: ClosedRange<Double>
        if imperial {
            displayedRange = ClosedRange(
                uncheckedBounds: (
                    lower: WeightCheckInPolicy.kilogramsRange.lowerBound
                        * WeightCheckInPolicy.poundsPerKilogram,
                    upper: WeightCheckInPolicy.kilogramsRange.upperBound
                        * WeightCheckInPolicy.poundsPerKilogram
                )
            )
        } else {
            displayedRange = WeightCheckInPolicy.kilogramsRange
        }
        return candidates.flatMap { candidate -> [(value: Double, score: Double)] in
            numberStrings(in: candidate.text).compactMap { token in
                guard
                    let value = Double(token.replacingOccurrences(of: ",", with: ".")),
                    displayedRange.contains(value)
                else { return nil }
                let normalized = candidate.text.lowercased()
                let unitBonus = normalized.contains(imperial ? "lb" : "kg") ? 1.0 : 0.0
                let decimalBonus = token.contains(".") || token.contains(",") ? 0.25 : 0
                return (
                    value,
                    Double(candidate.confidence) + candidate.area * 8 + unitBonus + decimalBonus
                )
            }
        }
        .max { $0.score < $1.score }?
        .value
    }

    private static func numberStrings(in text: String) -> [String] {
        guard
            let expression = try? NSRegularExpression(
                pattern: #"(?<!\d)\d{2,3}(?:[.,]\d{1,2})?(?!\d)"#
            )
        else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }
}
