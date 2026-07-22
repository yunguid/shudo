import Foundation

protocol OnboardingServing: Sendable {
    func createProposal(
        text: String,
        audioData: Data?,
        timezone: String,
        clientRequestID: UUID
    ) async throws -> OnboardingProposalResult

    func applyProposal(
        onboardingID: UUID,
        overrides: OnboardingOverrides
    ) async throws

    func fetchAuthoritativeProfile() async throws -> Profile
}

struct OnboardingService: OnboardingServing, Sendable {
    enum ServiceError: LocalizedError, Equatable {
        case invalidCapture
        case audioTooLarge
        case invalidResponse
        case stillProcessing
        case alreadyApplied
        case analysisFailed
        case server(statusCode: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .invalidCapture:
                return "Add a voice note or a short description."
            case .audioTooLarge:
                return "That voice note is too large. Record a shorter one and try again."
            case .invalidResponse:
                return "The server returned an unexpected response."
            case .stillProcessing:
                return "Your targets are still being prepared. Try again in a moment."
            case .alreadyApplied:
                return "Your targets were already saved."
            case .analysisFailed:
                return "Those targets couldn’t be prepared. Start a new voice setup."
            case .server(_, let message):
                return message
            }
        }
    }

    static let maximumAudioBytes = 25 * 1_024 * 1_024

    private struct WireResponse: Decodable {
        let onboardingID: UUID
        let status: OnboardingAnalysisStatus
        let transcript: String?
        let recommendation: OnboardingProposal?

        private enum CodingKeys: String, CodingKey {
            case onboardingID = "onboarding_id"
            case status
            case transcript
            case recommendation
        }
    }

    private struct ApplyPayload: Encodable {
        let onboardingID: UUID
        let overrides: OnboardingOverrides

        private enum CodingKeys: String, CodingKey {
            case onboardingID = "onboarding_id"
            case overrides
        }
    }

    private let supabaseURL: URL
    private let publishableKey: String
    private let session: URLSession
    private let sessionJWTProvider: @Sendable () async throws -> String
    private let userIDProvider: @Sendable () async throws -> String

    init(
        supabaseURL: URL = AppConfig.supabaseURL,
        publishableKey: String = AppConfig.supabaseAnonKey,
        session: URLSession = .shared,
        sessionJWTProvider: @escaping @Sendable () async throws -> String = {
            try await AuthSessionManager.shared.getAccessToken()
        },
        userIDProvider: @escaping @Sendable () async throws -> String = {
            guard let userID = AuthSessionManager.shared.userId else {
                throw ServiceError.server(statusCode: 401, message: "Sign in again to continue.")
            }
            return userID
        }
    ) {
        self.supabaseURL = supabaseURL
        self.publishableKey = publishableKey
        self.session = session
        self.sessionJWTProvider = sessionJWTProvider
        self.userIDProvider = userIDProvider
    }

    func createProposal(
        text: String,
        audioData: Data?,
        timezone: String,
        clientRequestID: UUID
    ) async throws -> OnboardingProposalResult {
        let jwt = try await sessionJWTProvider()
        let request = try Self.makeProposalRequest(
            text: text,
            audioData: audioData,
            timezone: timezone,
            clientRequestID: clientRequestID,
            jwt: jwt,
            supabaseURL: supabaseURL,
            publishableKey: publishableKey,
            boundary: UUID().uuidString
        )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }
        return try Self.parseProposalResponse(statusCode: http.statusCode, data: data)
    }

    func applyProposal(
        onboardingID: UUID,
        overrides: OnboardingOverrides
    ) async throws {
        let jwt = try await sessionJWTProvider()
        let request = try Self.makeApplyRequest(
            onboardingID: onboardingID,
            overrides: overrides,
            jwt: jwt,
            supabaseURL: supabaseURL,
            publishableKey: publishableKey
        )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.serverError(statusCode: http.statusCode, data: data)
        }
        let wire = try Self.decoder.decode(WireResponse.self, from: data)
        guard wire.status == .applied, wire.onboardingID == onboardingID else {
            throw ServiceError.invalidResponse
        }
    }

    func fetchAuthoritativeProfile() async throws -> Profile {
        let userID = try await userIDProvider()
        guard let profile = try await SupabaseService().fetchProfile(userId: userID) else {
            throw ServiceError.invalidResponse
        }
        return profile
    }

    static func makeProposalRequest(
        text: String,
        audioData: Data?,
        timezone: String,
        clientRequestID: UUID,
        jwt: String,
        supabaseURL: URL,
        publishableKey: String,
        boundary: String
    ) throws -> URLRequest {
        guard OnboardingCapturePolicy.canSubmit(
            text: text,
            hasAudio: audioData?.isEmpty == false,
            isSubmitting: false
        ) else {
            throw ServiceError.invalidCapture
        }
        if let audioData, audioData.count > maximumAudioBytes {
            throw ServiceError.audioTooLarge
        }

        var request = URLRequest(url: endpointURL(supabaseURL: supabaseURL))
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = multipartBody(
            boundary: boundary,
            clientRequestID: clientRequestID,
            timezone: timezone,
            text: OnboardingCapturePolicy.normalizedText(text),
            audioData: audioData
        )
        return request
    }

    static func makeApplyRequest(
        onboardingID: UUID,
        overrides: OnboardingOverrides,
        jwt: String,
        supabaseURL: URL,
        publishableKey: String
    ) throws -> URLRequest {
        var request = URLRequest(url: endpointURL(supabaseURL: supabaseURL))
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            ApplyPayload(onboardingID: onboardingID, overrides: overrides)
        )
        return request
    }

    static func parseProposalResponse(statusCode: Int, data: Data) throws -> OnboardingProposalResult {
        guard (200..<300).contains(statusCode) else {
            throw serverError(statusCode: statusCode, data: data)
        }
        let wire: WireResponse
        do {
            wire = try decoder.decode(WireResponse.self, from: data)
        } catch {
            throw ServiceError.invalidResponse
        }

        switch wire.status {
        case .analyzing:
            throw ServiceError.stillProcessing
        case .failed:
            throw ServiceError.analysisFailed
        case .applied:
            throw ServiceError.alreadyApplied
        case .proposed:
            guard let transcript = wire.transcript?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ), !transcript.isEmpty, let recommendation = wire.recommendation else {
                throw ServiceError.invalidResponse
            }
            return OnboardingProposalResult(
                onboardingID: wire.onboardingID,
                transcript: transcript,
                proposal: recommendation
            )
        }
    }

    private static var decoder: JSONDecoder {
        JSONDecoder()
    }

    private static func endpointURL(supabaseURL: URL) -> URL {
        supabaseURL
            .appendingPathComponent("functions")
            .appendingPathComponent("v1")
            .appendingPathComponent("onboard_profile")
    }

    private static func serverError(statusCode: Int, data: Data) -> ServiceError {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let message = (object?["error"] as? String)
            ?? (object?["message"] as? String)
            ?? "The setup couldn’t be completed."
        return .server(statusCode: statusCode, message: message)
    }

    private static func multipartBody(
        boundary: String,
        clientRequestID: UUID,
        timezone: String,
        text: String,
        audioData: Data?
    ) -> Data {
        var body = Data()

        func append(_ string: String) {
            body.append(Data(string.utf8))
        }

        func appendField(name: String, value: String) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append(value)
            append("\r\n")
        }

        appendField(name: "client_request_id", value: clientRequestID.uuidString.lowercased())
        appendField(name: "timezone", value: timezone)
        appendField(name: "text", value: text)
        if let audioData, !audioData.isEmpty {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"audio\"; filename=\"onboarding.m4a\"\r\n")
            append("Content-Type: audio/mp4\r\n\r\n")
            body.append(audioData)
            append("\r\n")
        }
        append("--\(boundary)--\r\n")
        return body
    }
}
