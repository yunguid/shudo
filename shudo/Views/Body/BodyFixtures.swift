#if DEBUG
    import SwiftUI
    import UIKit

    /// Offline Body tab: a mid-bulk sample state (lean bulk 162.5 → 175 lb,
    /// five weeks in, a scale that arrived late so weights are sparse, ten
    /// check-in photos) for PolishPreview screenshots and UI tests.
    ///
    /// Launch with `-shudoPolishPreview body`, optionally plus
    /// `-shudoBodyPreview <options>` (comma-separated): `noscale` (no
    /// weigh-ins yet), `empty` (today not checked in), `revealed` (veil off),
    /// and one action: `compare`, `camera`, `review`, `weight`, `viewer`.
    /// `-shudoBodyCameraFixture <path>` makes the camera shoot that image.
    enum BodyFixtures {
        static let timezone = "America/New_York"
        static let userId = "00000000-0000-4000-8000-000000000001"

        static var options: Set<String> {
            let arguments = ProcessInfo.processInfo.arguments
            guard let flag = arguments.firstIndex(of: "-shudoBodyPreview"),
                arguments.indices.contains(flag + 1)
            else { return [] }
            return Set(arguments[flag + 1].split(separator: ",").map { String($0).lowercased() })
        }

        @MainActor
        static func previewScreen() -> some View {
            let options = options
            let action = options.compactMap(BodyPreviewAction.init(rawValue:)).first
            return BodyScreen(
                previewModel: model(noScale: options.contains("noscale"), empty: options.contains("empty")),
                previewAction: action,
                revealed: options.contains("revealed")
            )
        }

        static var profile: Profile {
            Profile(
                userId: userId,
                timezone: timezone,
                dailyMacroTarget: MacroTarget(caloriesKcal: 2_900, proteinG: 175, carbsG: 365, fatG: 82),
                units: "imperial",
                heightCM: 177.8,
                weightKG: BodyUnits.kilograms(pounds: 162.5),
                targetWeightKG: BodyUnits.kilograms(pounds: 175),
                displayName: "Luke",
                activityLevel: .active,
                goalType: .gain,
                goalNotes: "Lean bulk to 175. Lift four days a week.",
                onboardingStatus: .completed,
                onboardingCompletedAt: Date()
            )
        }

        @MainActor
        static func model(noScale: Bool = false, empty: Bool = false) -> BodyViewModel {
            let today = LocalDayMath.today(in: timezone)
            let checkIns = checkIns(today: today, noScale: noScale, empty: empty)
            let settings = BodyGoalSettings(
                goalType: .gain,
                targetWeightKG: BodyUnits.kilograms(pounds: 175),
                selfReportedWeightKG: BodyUnits.kilograms(pounds: 162.5),
                goalDate: nil,
                goalStartedOn: LocalDayMath.adding(-34, to: today),
                goalStartWeightKG: BodyUnits.kilograms(pounds: 162.5),
                physiqueAIReviewEnabled: false
            )
            let nutrition = nutrition(today: today)
            let service = FixtureBodyService(checkIns: checkIns, nutrition: nutrition)
            return BodyViewModel(
                previewProfile: profile,
                settings: settings,
                checkIns: checkIns,
                nutrition: nutrition,
                summaries: summaries(today: today),
                service: service,
                today: today
            )
        }

        /// Ten photos over the last twelve days (two misses), weigh-ins from
        /// the day the scale showed up three weeks ago.
        static func checkIns(today: String, noScale: Bool, empty: Bool) -> [WeightCheckIn] {
            let weighIns: [Int: Double] =
                noScale
                ? [:]
                : [-20: 163.6, -16: 163.9, -13: 164.4, -9: 164.2, -6: 164.9, -3: 165.3, -1: 165.1]
            var photoDays = [0, -1, -2, -3, -4, -5, -7, -8, -9, -11]
            if empty { photoDays.removeAll { $0 == 0 } }
            let days = Set(photoDays).union(weighIns.keys).sorted(by: >)
            return days.compactMap { offset -> WeightCheckIn? in
                guard let localDay = LocalDayMath.adding(offset, to: today),
                    let date = LocalDayMath.date(localDay)
                else { return nil }
                let morning = date.addingTimeInterval(11 * 3_600 + 12 * 60)  // ~7:12 AM New York
                let hasPhoto = photoDays.contains(offset)
                return WeightCheckIn(
                    id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", 100 + abs(offset)))
                        ?? UUID(),
                    localDay: localDay,
                    weightKG: weighIns[offset].map(BodyUnits.kilograms(pounds:)),
                    progressPhotoPath: hasPhoto
                        ? String(format: "%@/%@/progress-00000000-0000-4000-8000-%012d.jpg", userId, localDay, abs(offset))
                        : nil,
                    note: offset == -4 ? "Pumped from legs, slept 6h." : nil,
                    photoPose: hasPhoto ? .frontRelaxed : nil,
                    photoCapturedAt: hasPhoto ? morning : nil,
                    coachReview: offset == -1
                        ? PhysiqueCoachReview(
                            headline: "Delts are filling out; waist hasn't moved. Clean bulk.",
                            coachNote: nil, bulkQuality: "clean", observations: [])
                        : nil,
                    createdAt: morning,
                    updatedAt: morning
                )
            }
        }

        static func nutrition(today: String) -> BodyNutritionHistory {
            let totals = (0..<84).compactMap { offset -> DailyNutritionTotal? in
                guard offset % 9 != 4, let day = LocalDayMath.adding(-offset, to: today) else { return nil }
                let wave = Double((offset * 7) % 11) / 10  // 0…1
                let calories = 2_900 * (0.82 + 0.33 * wave)
                let protein = 175 * (0.8 + 0.3 * Double((offset * 5) % 7) / 6)
                return DailyNutritionTotal(
                    localDay: day,
                    proteinG: protein,
                    carbsG: calories * 0.5 / 4,
                    fatG: calories * 0.26 / 9,
                    caloriesKcal: calories,
                    entryCount: offset == 0 ? 2 : 4
                )
            }
            return BodyNutritionHistory(totals: totals, targetHistory: [])
        }

        static func summaries(today: String) -> [WeeklyInsightSummary] {
            let headlines = [
                ("Protein was locked in; Saturday ran light again", "Five of seven days hit 175 g. Calories landed in the bulk lane on four days; Saturday stopped at 2,150 after a late start."),
                ("Bulk on track, breakfast still the weak link", "Weekday dinners carried the calories. Two mornings started after 11 with nothing logged before lunch."),
                ("First full week of the bulk", "Logged every day. Calories averaged 2,760, a touch under target, with protein steady."),
            ]
            return headlines.enumerated().compactMap { index, item in
                guard let startDay = LocalDayMath.adding(-7 * (index + 1) - 6, to: today),
                    let endDay = LocalDayMath.adding(6, to: startDay),
                    let start = LocalDayMath.date(startDay), let end = LocalDayMath.date(endDay)
                else { return nil }
                return WeeklyInsightSummary(
                    weekStart: start, weekEnd: end, headline: item.0, narrative: item.1,
                    repeatedFoods: [WeeklyRepeatedFood(name: "Chicken rice bowl", count: 4)],
                    patterns: ["Every day with a 40 g breakfast finished on plan"],
                    suggestions: ["Add a 600 kcal shake on Saturdays before noon"])
            }
        }
    }

    struct FixtureBodyService: BodyServicing {
        let checkIns: [WeightCheckIn]
        let nutrition: BodyNutritionHistory

        func checkIns(limit: Int) async throws -> [WeightCheckIn] { Array(checkIns.prefix(limit)) }
        func goalSettings() async throws -> BodyGoalSettings { BodyGoalSettings(profile: BodyFixtures.profile) }
        func nutrition(timezone: String) async throws -> BodyNutritionHistory { nutrition }
        func weeklySummaries(limit: Int) async throws -> [WeeklyInsightSummary] { [] }

        func photoData(path: String) async throws -> Data {
            let ordered = checkIns.filter(\.hasPhoto).sorted { $0.localDay < $1.localDay }
            let index = ordered.firstIndex { $0.progressPhotoPath == path } ?? 0
            let image = BodyFixtureArt.physique(progress: Double(index) / Double(max(ordered.count - 1, 1)), seed: index)
            guard let data = image.jpegData(compressionQuality: 0.85) else { throw CocoaError(.fileReadCorruptFile) }
            return data
        }

        func save(
            _ draft: BodyCheckInDraft, replacing existing: WeightCheckIn?, updatesProfileWeight: Bool
        ) async throws -> WeightCheckIn {
            try? await Task.sleep(for: .milliseconds(400))
            let photoPath = draft.photoJPEG.map { _ in
                "\(BodyFixtures.userId)/\(draft.localDay)/progress-\(UUID().uuidString.lowercased()).jpg"
            }
            return WeightCheckIn(
                id: existing?.id ?? UUID(),
                localDay: draft.localDay,
                weightKG: draft.weightKG ?? existing?.weightKG,
                progressPhotoPath: photoPath ?? existing?.progressPhotoPath,
                note: draft.note ?? existing?.note,
                photoPose: draft.pose ?? existing?.photoPose,
                photoCapturedAt: draft.capturedAt ?? existing?.photoCapturedAt,
                createdAt: existing?.createdAt ?? Date(),
                updatedAt: Date()
            )
        }

        func removePhoto(_ checkIn: WeightCheckIn) async throws -> WeightCheckIn? {
            guard let weight = checkIn.weightKG else { return nil }
            return WeightCheckIn(
                id: checkIn.id, localDay: checkIn.localDay, weightKG: weight, progressPhotoPath: nil,
                createdAt: checkIn.createdAt, updatedAt: Date())
        }

        func anchorGoal(startedOn: String, startWeightKG: Double) async throws {}
    }

    /// Drawn stand-ins for physique photos (no real bodies in the repo).
    enum BodyFixtureArt {
        static let cameraFixture: UIImage? = {
            let arguments = ProcessInfo.processInfo.arguments
            if let flag = arguments.firstIndex(of: "-shudoBodyCameraFixture"),
                arguments.indices.contains(flag + 1),
                let image = UIImage(contentsOfFile: arguments[flag + 1])
            {
                return image
            }
            return physique(progress: 1, seed: 11)
        }()

        /// A 3:4 front-relaxed silhouette; `progress` 0…1 widens the
        /// shoulders and arms a little, like five weeks of a lean bulk.
        static func physique(progress: Double, seed: Int) -> UIImage {
            let size = CGSize(width: 600, height: 800)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            return UIGraphicsImageRenderer(size: size, format: format).image { context in
                let cg = context.cgContext
                let light = 0.03 * Double(seed % 3)
                let colors = [
                    UIColor(red: 0.27 + light, green: 0.23 + light, blue: 0.20, alpha: 1).cgColor,
                    UIColor(red: 0.11, green: 0.10, blue: 0.09, alpha: 1).cgColor,
                ]
                if let gradient = CGGradient(
                    colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])
                {
                    cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
                }
                UIColor(white: 0, alpha: 0.18).setFill()
                cg.fill(CGRect(x: 0, y: 690, width: size.width, height: 110))

                let skin = UIColor(red: 0.70, green: 0.53, blue: 0.42, alpha: 1)
                let shade = UIColor(red: 0.55, green: 0.40, blue: 0.31, alpha: 1)
                let cx = size.width / 2
                let shoulder = 118 + 16 * progress
                let waist = 74 + 3 * progress
                let arm = 30 + 7 * progress

                skin.setFill()
                UIBezierPath(ovalIn: CGRect(x: cx - 42, y: 70, width: 84, height: 104)).fill()
                UIBezierPath(rect: CGRect(x: cx - 22, y: 160, width: 44, height: 46)).fill()

                // Arms hang slightly away from the torso.
                for side in [-1.0, 1.0] {
                    let arms = UIBezierPath()
                    let top = CGPoint(x: cx + side * (shoulder - arm * 0.35), y: 222)
                    arms.move(to: CGPoint(x: top.x - side * arm * 0.4, y: top.y - 8))
                    arms.addQuadCurve(
                        to: CGPoint(x: cx + side * (shoulder + arm * 0.9), y: 470),
                        controlPoint: CGPoint(x: cx + side * (shoulder + arm * 1.3), y: 300))
                    arms.addLine(to: CGPoint(x: cx + side * (shoulder + arm * 0.05), y: 478))
                    arms.addQuadCurve(
                        to: CGPoint(x: top.x - side * arm * 0.6, y: 280),
                        controlPoint: CGPoint(x: cx + side * (shoulder + arm * 0.1), y: 330))
                    arms.close()
                    skin.setFill()
                    arms.fill()
                }

                let torso = UIBezierPath()
                torso.move(to: CGPoint(x: cx - 30, y: 200))
                torso.addQuadCurve(to: CGPoint(x: cx - shoulder, y: 236), controlPoint: CGPoint(x: cx - shoulder * 0.7, y: 204))
                torso.addQuadCurve(to: CGPoint(x: cx - waist, y: 470), controlPoint: CGPoint(x: cx - shoulder * 0.95, y: 360))
                torso.addLine(to: CGPoint(x: cx - waist - 6, y: 520))
                torso.addLine(to: CGPoint(x: cx + waist + 6, y: 520))
                torso.addLine(to: CGPoint(x: cx + waist, y: 470))
                torso.addQuadCurve(to: CGPoint(x: cx + shoulder, y: 236), controlPoint: CGPoint(x: cx + shoulder * 0.95, y: 360))
                torso.addQuadCurve(to: CGPoint(x: cx + 30, y: 200), controlPoint: CGPoint(x: cx + shoulder * 0.7, y: 204))
                torso.close()
                skin.setFill()
                torso.fill()

                // Chest + ab definition, a touch sharper as progress grows.
                shade.withAlphaComponent(0.55 + 0.2 * progress).setStroke()
                let detail = UIBezierPath()
                detail.lineWidth = 3
                detail.move(to: CGPoint(x: cx - shoulder * 0.72, y: 300))
                detail.addQuadCurve(to: CGPoint(x: cx, y: 318), controlPoint: CGPoint(x: cx - shoulder * 0.35, y: 334))
                detail.addQuadCurve(to: CGPoint(x: cx + shoulder * 0.72, y: 300), controlPoint: CGPoint(x: cx + shoulder * 0.35, y: 334))
                detail.move(to: CGPoint(x: cx, y: 330))
                detail.addLine(to: CGPoint(x: cx, y: 490))
                for y in stride(from: 372.0, through: 452.0, by: 40) {
                    detail.move(to: CGPoint(x: cx - 34, y: y))
                    detail.addLine(to: CGPoint(x: cx + 34, y: y))
                }
                detail.stroke()

                UIColor(red: 0.13, green: 0.13, blue: 0.16, alpha: 1).setFill()
                UIBezierPath(roundedRect: CGRect(x: cx - waist - 10, y: 506, width: 2 * waist + 20, height: 112), cornerRadius: 14).fill()
                skin.setFill()
                for side in [-1.0, 1.0] {
                    UIBezierPath(
                        roundedRect: CGRect(x: cx + side * 40 - 34, y: 600, width: 68, height: 190),
                        cornerRadius: 30
                    ).fill()
                }
            }
        }
    }
#endif
