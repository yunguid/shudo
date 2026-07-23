import Foundation

protocol EntryReanalysisServing {
    func reanalyzeEntry(id: UUID, context: String) async throws -> APIService.ReanalysisResult
    func correctEntry(
        id: UUID,
        text: String?,
        audioData: Data?,
        clientRequestId: UUID
    ) async throws -> APIService.ReanalysisResult
}

extension EntryReanalysisServing {
    func correctEntry(
        id: UUID,
        text: String?,
        audioData: Data?,
        clientRequestId: UUID
    ) async throws -> APIService.ReanalysisResult {
        guard audioData == nil, let text else { throw APIService.APIError.invalidCorrection }
        return try await reanalyzeEntry(id: id, context: text)
    }
}

protocol AccountDeletionServing {
    func deleteAccount(confirmation: String) async throws
}

public struct APIService: EntryReanalysisServing, AccountDeletionServing {
    public struct CreateEntryResult: Equatable {
        public let entryId: UUID
        public let status: EntryStatus
    }

    public enum ResumeEntryResult: Equatable {
        case accepted(status: EntryStatus)
        case conflict(message: String)
    }

    public struct ReanalysisResult: Equatable {
        public let entryId: UUID
        public let status: EntryStatus
    }

    public enum APIError: LocalizedError {
        case server(statusCode: Int, message: String)
        case invalidResponse
        case invalidCorrection

        public var errorDescription: String? {
            switch self {
            case .server(_, let message): return message
            case .invalidResponse: return "The server returned an unexpected response."
            case .invalidCorrection: return "Record or type what should change."
            }
        }
    }

    let supabaseUrl: URL
    let supabaseAnonKey: String
    let sessionJWTProvider: () async throws -> String

    public init(supabaseUrl: URL, supabaseAnonKey: String, sessionJWTProvider: @escaping () async throws -> String) {
        self.supabaseUrl = supabaseUrl
        self.supabaseAnonKey = supabaseAnonKey
        self.sessionJWTProvider = sessionJWTProvider
    }

    public func createEntry(
        text: String?,
        audioData: Data?,
        imageJPEG: Data?,
        timezone: String,
        localDay: String,
        clientRequestId: UUID
    ) async throws -> CreateEntryResult {
        var req = URLRequest(url: supabaseUrl.appendingPathComponent("/functions/v1/create_entry"))
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        let jwt = try await sessionJWTProvider()
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        req.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")

        let boundary = UUID().uuidString
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = makeMultipart(
            boundary: boundary,
            text: text,
            audioData: audioData,
            imageJPEG: imageJPEG,
            timezone: timezone,
            localDay: localDay,
            clientRequestId: clientRequestId
        )

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard http.statusCode == 202 || http.statusCode == 200 else {
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let message = (object?["error"] as? String)
                ?? (object?["message"] as? String)
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw APIError.server(statusCode: http.statusCode, message: message)
        }

        // Queued response: { entry_id, status: "queued" }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let idStr = obj["entry_id"] as? String,
           let id = UUID(uuidString: idStr) {
            let status = (obj["status"] as? String).flatMap(EntryStatus.init(rawValue:)) ?? .queued
            return CreateEntryResult(entryId: id, status: status)
        }
        throw APIError.invalidResponse
    }

    public func resumeEntry(id: UUID) async throws -> ResumeEntryResult {
        let jwt = try await sessionJWTProvider()
        let request = try makeResumeRequest(entryId: id, jwt: jwt)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        return try Self.parseResumeResponse(statusCode: http.statusCode, data: data)
    }

    public func reanalyzeEntry(id: UUID, context: String) async throws -> ReanalysisResult {
        let jwt = try await sessionJWTProvider()
        let request = try makeReanalysisRequest(entryId: id, context: context, jwt: jwt)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        return try Self.parseReanalysisResponse(
            statusCode: http.statusCode,
            data: data,
            fallbackEntryId: id
        )
    }

    public func correctEntry(
        id: UUID,
        text: String?,
        audioData: Data?,
        clientRequestId: UUID
    ) async throws -> ReanalysisResult {
        let jwt = try await sessionJWTProvider()
        let request = try makeCorrectionRequest(
            entryId: id,
            text: text,
            audioData: audioData,
            clientRequestId: clientRequestId,
            jwt: jwt
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        return try Self.parseReanalysisResponse(
            statusCode: http.statusCode,
            data: data,
            fallbackEntryId: id
        )
    }

    public func deleteAccount(confirmation: String) async throws {
        let jwt = try await sessionJWTProvider()
        let request = try makeDeleteAccountRequest(confirmation: confirmation, jwt: jwt)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let message = (object?["error"] as? String)
                ?? (object?["message"] as? String)
                ?? "The account couldn’t be deleted. Nothing was changed."
            throw APIError.server(statusCode: http.statusCode, message: message)
        }
    }

    func makeDeleteAccountRequest(confirmation: String, jwt: String) throws -> URLRequest {
        guard AccountDeletionPolicy.isConfirmed(confirmation) else {
            throw APIError.server(statusCode: 400, message: "Type DELETE to confirm account deletion.")
        }
        var request = URLRequest(url: supabaseUrl.appendingPathComponent("/functions/v1/delete_account"))
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "confirmation": confirmation
        ])
        return request
    }

    func makeReanalysisRequest(entryId: UUID, context: String, jwt: String) throws -> URLRequest {
        guard EntryCorrectionPolicy.canSubmit(context) else { throw APIError.invalidCorrection }
        var request = URLRequest(url: supabaseUrl.appendingPathComponent("/functions/v1/reanalyze_entry"))
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "entry_id": entryId.uuidString.lowercased(),
            "context": EntryCorrectionPolicy.normalized(context)
        ])
        return request
    }

    func makeCorrectionRequest(
        entryId: UUID,
        text: String?,
        audioData: Data?,
        clientRequestId: UUID,
        jwt: String
    ) throws -> URLRequest {
        let normalizedText = text.map(EntryCorrectionPolicy.normalized)
        let hasText = normalizedText?.isEmpty == false
        let hasAudio = audioData?.isEmpty == false
        guard EntryCorrectionPolicy.canSubmit(
            text: normalizedText ?? "",
            hasAudio: hasAudio
        ) else {
            throw APIError.invalidCorrection
        }
        if let audioData,
           !EntryCorrectionPolicy.audioIsWithinUploadLimit(audioData.count) {
            throw APIError.server(
                statusCode: 413,
                message: "That voice correction is too large. Record a shorter one."
            )
        }

        var request = URLRequest(url: supabaseUrl.appendingPathComponent("/functions/v1/correct_entry"))
        request.httpMethod = "POST"
        request.timeoutInterval = 130
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = makeCorrectionMultipart(
            boundary: boundary,
            entryId: entryId,
            text: hasText ? normalizedText : nil,
            audioData: audioData,
            clientRequestId: clientRequestId
        )
        return request
    }

    func makeCorrectionMultipart(
        boundary: String,
        entryId: UUID,
        text: String?,
        audioData: Data?,
        clientRequestId: UUID
    ) -> Data {
        var data = Data()
        func part(_ name: String, _ value: String) {
            data.append("--\(boundary)\r\n".data(using: .utf8)!)
            data.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            data.append("\(value)\r\n".data(using: .utf8)!)
        }
        part("entry_id", entryId.uuidString.lowercased())
        part("client_request_id", clientRequestId.uuidString.lowercased())
        if let text, !text.isEmpty { part("text", text) }
        if let audioData, !audioData.isEmpty {
            data.append("--\(boundary)\r\n".data(using: .utf8)!)
            data.append(
                "Content-Disposition: form-data; name=\"audio\"; filename=\"correction.m4a\"\r\n"
                    .data(using: .utf8)!
            )
            data.append("Content-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
            data.append(audioData)
            data.append("\r\n".data(using: .utf8)!)
        }
        data.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return data
    }

    static func parseReanalysisResponse(
        statusCode: Int,
        data: Data,
        fallbackEntryId: UUID
    ) throws -> ReanalysisResult {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if statusCode == 200 || statusCode == 202 {
            let entryId = (object?["entry_id"] as? String).flatMap(UUID.init(uuidString:))
                ?? fallbackEntryId
            let status = (object?["status"] as? String).flatMap(EntryStatus.init(rawValue:))
                ?? .queued
            return ReanalysisResult(entryId: entryId, status: status)
        }

        let message = (object?["error"] as? String)
            ?? (object?["message"] as? String)
            ?? "The meal couldn’t be re-analyzed."
        throw APIError.server(statusCode: statusCode, message: message)
    }

    func makeResumeRequest(entryId: UUID, jwt: String) throws -> URLRequest {
        var request = URLRequest(url: supabaseUrl.appendingPathComponent("/functions/v1/resume_entry"))
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "entry_id": entryId.uuidString.lowercased()
        ])
        return request
    }

    static func parseResumeResponse(statusCode: Int, data: Data) throws -> ResumeEntryResult {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let message = (object?["error"] as? String)
            ?? (object?["message"] as? String)

        if statusCode == 200 || statusCode == 202 {
            let status = (object?["status"] as? String)
                .flatMap(EntryStatus.init(rawValue:))
                ?? .queued
            return .accepted(status: status)
        }

        if statusCode == 409 {
            return .conflict(
                message: message ?? "This meal is already running or has used all retry attempts."
            )
        }

        throw APIError.server(
            statusCode: statusCode,
            message: message ?? "The meal couldn’t be retried."
        )
    }

    func makeMultipart(
        boundary: String,
        text: String?,
        audioData: Data?,
        imageJPEG: Data?,
        timezone: String,
        localDay: String,
        clientRequestId: UUID
    ) -> Data {
        var data = Data()
        func part(_ name: String, _ value: String) {
            data.append("--\(boundary)\r\n".data(using: .utf8)!)
            data.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            data.append("\(value)\r\n".data(using: .utf8)!)
        }
        part("timezone", timezone)
        part("local_day", localDay)
        part("client_request_id", clientRequestId.uuidString.lowercased())
        if let text {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { part("text", trimmed) }
        }
        if let raw = audioData {
            data.append("--\(boundary)\r\n".data(using: .utf8)!)
            data.append("Content-Disposition: form-data; name=\"audio\"; filename=\"voice.m4a\"\r\n".data(using: .utf8)!)
            data.append("Content-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
            data.append(raw); data.append("\r\n".data(using: .utf8)!)
        }
        if let imageJPEG, !imageJPEG.isEmpty {
            data.append("--\(boundary)\r\n".data(using: .utf8)!)
            data.append("Content-Disposition: form-data; name=\"image\"; filename=\"photo.jpg\"\r\n".data(using: .utf8)!)
            data.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
            data.append(imageJPEG); data.append("\r\n".data(using: .utf8)!)
        }
        data.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return data
    }

    public func deleteEntry(id: UUID) async throws {
        var request = URLRequest(url: supabaseUrl.appendingPathComponent("/functions/v1/delete_entry"))
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(try await sessionJWTProvider())", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["entry_id": id.uuidString.lowercased()])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let message = (object?["error"] as? String)
                ?? (object?["message"] as? String)
                ?? "The meal couldn’t be deleted."
            throw APIError.server(statusCode: http.statusCode, message: message)
        }
    }
}
