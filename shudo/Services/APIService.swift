import Foundation
import UIKit

public struct APIService {
    public struct CreateEntryResult: Equatable {
        public let entryId: UUID
        public let status: EntryStatus
    }

    public enum ResumeEntryResult: Equatable {
        case accepted(status: EntryStatus)
        case conflict(message: String)
    }

    public enum APIError: LocalizedError {
        case server(statusCode: Int, message: String)
        case invalidResponse

        public var errorDescription: String? {
            switch self {
            case .server(_, let message): return message
            case .invalidResponse: return "The server returned an unexpected response."
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
        image: UIImage?,
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
        req.httpBody = try makeMultipart(
            boundary: boundary,
            text: text,
            audioData: audioData,
            image: image,
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
        image: UIImage?,
        timezone: String,
        localDay: String,
        clientRequestId: UUID
    ) throws -> Data {
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
        if let image, let jpg = ImageProcessor.jpegData(from: image) {
            data.append("--\(boundary)\r\n".data(using: .utf8)!)
            data.append("Content-Disposition: form-data; name=\"image\"; filename=\"photo.jpg\"\r\n".data(using: .utf8)!)
            data.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
            data.append(jpg); data.append("\r\n".data(using: .utf8)!)
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
