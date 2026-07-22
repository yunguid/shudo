import Foundation
import Testing
@testable import shudo

struct OnboardingTests {
    @Test func recalculationContextPreservesSavedFactsUnlessExplicitlyChanged() {
        let profile = Profile(
            userId: "user",
            timezone: "America/New_York",
            dailyMacroTarget: MacroTarget(
                caloriesKcal: 2_400,
                proteinG: 180,
                carbsG: 250,
                fatG: 75
            ),
            units: "imperial",
            heightCM: 180,
            weightKG: 82,
            targetWeightKG: 78,
            displayName: "Luke",
            activityLevel: .active,
            goalType: .maintain,
            goalNotes: "Keep strength"
        )

        let context = OnboardingCapturePolicy.proposalContext(
            userText: "Switch me to a slow fat-loss goal.",
            preserving: profile
        )

        #expect(context.hasPrefix("Switch me to a slow fat-loss goal."))
        #expect(context.contains("height_cm: 180.0"))
        #expect(context.contains("weight_kg: 82.0"))
        #expect(context.contains("activity_level: active"))
        #expect(context.contains("Preserve every value unless the user explicitly asks"))
        #expect(context.count <= OnboardingCapturePolicy.maximumTextCharacters)
    }
    @Test func launchPolicyUsesOnboardingStatusWithoutAConsentGate() {
        let base = Profile(
            userId: "user-1",
            timezone: "UTC",
            dailyMacroTarget: .defaultDaily,
            onboardingStatus: .completed
        )
        #expect(ProfileLaunchPolicy.destination(for: base) == .today)

        var pending = base
        pending.onboardingStatus = .pending
        #expect(ProfileLaunchPolicy.destination(for: pending) == .onboarding)

        var established = pending
        established.onboardingStatus = .completed
        #expect(ProfileLaunchPolicy.destination(for: established) == .today)

        established.onboardingStatus = nil
        #expect(ProfileLaunchPolicy.destination(for: established) == .loading)
    }

    @Test func capturePolicyRequiresVoiceOrTextAndBoundsTypedContext() {
        #expect(!OnboardingCapturePolicy.canSubmit(
            text: " \n ",
            hasAudio: false,
            isSubmitting: false
        ))
        #expect(OnboardingCapturePolicy.canSubmit(
            text: "",
            hasAudio: true,
            isSubmitting: false
        ))
        #expect(OnboardingCapturePolicy.canSubmit(
            text: "Gain muscle slowly",
            hasAudio: false,
            isSubmitting: false
        ))
        #expect(!OnboardingCapturePolicy.canSubmit(
            text: "Goal",
            hasAudio: true,
            isSubmitting: true
        ))

        let oversized = String(
            repeating: "x",
            count: OnboardingCapturePolicy.maximumTextCharacters + 1
        )
        #expect(!OnboardingCapturePolicy.canSubmit(
            text: oversized,
            hasAudio: false,
            isSubmitting: false
        ))
        #expect(
            OnboardingCapturePolicy.normalizedText("  \(oversized)  ").count
                == OnboardingCapturePolicy.maximumTextCharacters
        )
    }

    @Test func proposalRequestUsesAuthenticatedMultipartContract() throws {
        let requestID = try #require(
            UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        )
        let request = try OnboardingService.makeProposalRequest(
            text: "  I want to gain muscle.  ",
            audioData: Data([0x01, 0x02, 0x03]),
            timezone: "America/New_York",
            clientRequestID: requestID,
            jwt: "session-token",
            supabaseURL: try #require(URL(string: "https://example.supabase.co")),
            publishableKey: "sb_publishable_example",
            boundary: "test-boundary"
        )
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)

        #expect(request.url?.path == "/functions/v1/onboard_profile")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "apikey") == "sb_publishable_example")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer session-token")
        #expect(
            request.value(forHTTPHeaderField: "Content-Type")
                == "multipart/form-data; boundary=test-boundary"
        )
        #expect(body.contains(
            "name=\"client_request_id\"\r\n\r\naaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        ))
        #expect(body.contains("name=\"timezone\"\r\n\r\nAmerica/New_York"))
        #expect(body.contains("name=\"text\"\r\n\r\nI want to gain muscle."))
        #expect(body.contains(
            "name=\"audio\"; filename=\"onboarding.m4a\"\r\nContent-Type: audio/mp4"
        ))
    }

    @Test func proposalResponseDecodesEveryEditableRecommendationField() throws {
        let data = Data(
            """
            {
              "onboarding_id": "11111111-2222-3333-4444-555555555555",
              "status": "proposed",
              "transcript": "I am 5 feet 10 and want to gain muscle.",
              "recommendation": {
                "summary": "A gradual muscle-gain target.",
                "display_name": "Luke",
                "goal_type": "gain",
                "goal_notes": "Gain slowly while staying active.",
                "height_cm": 177.8,
                "weight_kg": 74.8,
                "target_weight_kg": 79.4,
                "activity_level": "active",
                "calories_kcal": 2900,
                "protein_g": 165,
                "carbs_g": 390,
                "fat_g": 75,
                "assumptions": ["Four active days per week"],
                "suggestions": ["Review after two weeks"]
              },
              "duplicate": false
            }
            """.utf8
        )

        let result = try OnboardingService.parseProposalResponse(statusCode: 201, data: data)
        #expect(
            result.onboardingID
                == UUID(uuidString: "11111111-2222-3333-4444-555555555555")
        )
        #expect(result.transcript == "I am 5 feet 10 and want to gain muscle.")
        #expect(result.proposal.displayName == "Luke")
        #expect(result.proposal.heightCM == 177.8)
        #expect(result.proposal.weightKG == 74.8)
        #expect(result.proposal.targetWeightKG == 79.4)
        #expect(result.proposal.activityLevel == .active)
        #expect(result.proposal.goalType == .gain)
        #expect(result.proposal.caloriesKcal == 2_900)
        #expect(result.proposal.proteinG == 165)
        #expect(result.proposal.carbsG == 390)
        #expect(result.proposal.fatG == 75)
    }

    @Test func nonProposalStatusesAreNeverPresentedAsEditableTargets() {
        let analyzing = Data(
            """
            {
              "onboarding_id": "11111111-2222-3333-4444-555555555555",
              "status": "analyzing",
              "transcript": null,
              "recommendation": null
            }
            """.utf8
        )
        let failed = Data(
            """
            {
              "onboarding_id": "11111111-2222-3333-4444-555555555555",
              "status": "failed",
              "transcript": null,
              "recommendation": null
            }
            """.utf8
        )

        #expect(throws: OnboardingService.ServiceError.stillProcessing) {
            try OnboardingService.parseProposalResponse(statusCode: 202, data: analyzing)
        }
        #expect(throws: OnboardingService.ServiceError.analysisFailed) {
            try OnboardingService.parseProposalResponse(statusCode: 200, data: failed)
        }
    }

    @Test func editableDraftValidatesBoundsAndEncodesClearedOptionalValues() throws {
        let proposal = OnboardingProposal(
            summary: "Maintain steadily.",
            displayName: "Luke",
            goalType: .maintain,
            goalNotes: "",
            heightCM: 177.8,
            weightKG: 74.8,
            targetWeightKG: nil,
            activityLevel: .moderate,
            caloriesKcal: 2_400,
            proteinG: 160,
            carbsG: 290,
            fatG: 70,
            assumptions: [],
            suggestions: []
        )
        var draft = OnboardingDraft(proposal: proposal, profileUnits: "metric")
        draft.displayName = "  "
        draft.targetWeight = ""
        draft.proteinG = "165.26"

        let overrides = try draft.validatedOverrides()
        #expect(overrides.displayName == nil)
        #expect(overrides.targetWeightKG == nil)
        #expect(overrides.proteinG == 165.3)

        let data = try JSONEncoder().encode(overrides)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["display_name"] is NSNull)
        #expect(object["target_weight_kg"] is NSNull)
        #expect(object["protein_g"] as? Double == 165.3)

        draft.caloriesKcal = "499"
        #expect(throws: OnboardingDraft.ValidationError.self) {
            try draft.validatedOverrides()
        }
    }

    @Test func imperialReviewUsesFeetInchesAndPoundsWithoutMetricRoundTripDrift() throws {
        let proposal = OnboardingProposal(
            summary: "Build gradually.",
            displayName: "Luke",
            goalType: .gain,
            goalNotes: "",
            heightCM: 180,
            weightKG: 74.8,
            targetWeightKG: 79.4,
            activityLevel: .active,
            caloriesKcal: 2_900,
            proteinG: 165,
            carbsG: 390,
            fatG: 75,
            assumptions: [],
            suggestions: []
        )
        var draft = OnboardingDraft(proposal: proposal, profileUnits: "imperial")

        #expect(draft.units == .imperial)
        #expect(draft.heightFeet == "5")
        #expect(draft.heightInches == "10.9")
        #expect(draft.weight == "164.9")
        #expect(draft.targetWeight == "175.0")

        let untouched = try draft.validatedOverrides()
        #expect(untouched.heightCM == 180)
        #expect(untouched.weightKG == 74.8)
        #expect(untouched.targetWeightKG == 79.4)

        draft.heightFeet = "6"
        draft.heightInches = "1.5"
        draft.weight = "180"
        draft.targetWeight = "190"

        let edited = try draft.validatedOverrides()
        #expect(edited.heightCM == 186.7)
        #expect(edited.weightKG == 81.6)
        #expect(edited.targetWeightKG == 86.2)

        draft.heightInches = "12"
        #expect(throws: OnboardingDraft.ValidationError.self) {
            try draft.validatedOverrides()
        }
    }

    @Test func metricReviewKeepsCentimetersAndKilogramsEditable() throws {
        let proposal = OnboardingProposal(
            summary: "Maintain steadily.",
            displayName: nil,
            goalType: .maintain,
            goalNotes: "",
            heightCM: 177.8,
            weightKG: 74.8,
            targetWeightKG: nil,
            activityLevel: .moderate,
            caloriesKcal: 2_400,
            proteinG: 160,
            carbsG: 290,
            fatG: 70,
            assumptions: [],
            suggestions: []
        )
        var draft = OnboardingDraft(proposal: proposal, profileUnits: "metric")

        #expect(draft.units == .metric)
        #expect(draft.heightCentimeters == "177.8")
        #expect(draft.weight == "74.8")

        draft.heightCentimeters = "181.2"
        draft.weight = "80.5"
        let edited = try draft.validatedOverrides()
        #expect(edited.heightCM == 181.2)
        #expect(edited.weightKG == 80.5)
        #expect(edited.targetWeightKG == nil)
    }

    @Test func applyRequestUsesExplicitJSONPhase() throws {
        let proposal = OnboardingProposal(
            summary: "Maintain steadily.",
            displayName: nil,
            goalType: .maintain,
            goalNotes: "",
            heightCM: nil,
            weightKG: nil,
            targetWeightKG: nil,
            activityLevel: .light,
            caloriesKcal: 2_200,
            proteinG: 150,
            carbsG: 250,
            fatG: 70,
            assumptions: [],
            suggestions: []
        )
        let overrides = try OnboardingDraft(
            proposal: proposal,
            profileUnits: "metric"
        ).validatedOverrides()
        let onboardingID = try #require(
            UUID(uuidString: "11111111-2222-3333-4444-555555555555")
        )
        let request = try OnboardingService.makeApplyRequest(
            onboardingID: onboardingID,
            overrides: overrides,
            jwt: "session-token",
            supabaseURL: try #require(URL(string: "https://example.supabase.co")),
            publishableKey: "sb_publishable_example"
        )
        let body = try #require(request.httpBody)
        let object = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let encodedOverrides = try #require(object["overrides"] as? [String: Any])

        #expect(request.url?.path == "/functions/v1/onboard_profile")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(
            object["onboarding_id"] as? String
                == "11111111-2222-3333-4444-555555555555"
        )
        #expect(encodedOverrides["goal_type"] as? String == "maintain")
        #expect(encodedOverrides["activity_level"] as? String == "light")
        #expect(encodedOverrides["display_name"] is NSNull)
    }
}
