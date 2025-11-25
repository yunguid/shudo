import Foundation
import UIKit

public struct APIService {
    let supabaseUrl: URL
    let supabaseAnonKey: String
    let sessionJWTProvider: () async throws -> String

    public init(supabaseUrl: URL, supabaseAnonKey: String, sessionJWTProvider: @escaping () async throws -> String) {
        self.supabaseUrl = supabaseUrl
        self.supabaseAnonKey = supabaseAnonKey
        self.sessionJWTProvider = sessionJWTProvider
    }

    public func createEntry(text: String?, audioData: Data?, image: UIImage?, timezone: String) async throws -> UUID {
        var req = URLRequest(url: supabaseUrl.appendingPathComponent("/functions/v1/create_entry"))
        req.httpMethod = "POST"
        let jwt = try await sessionJWTProvider()
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        req.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")

        let boundary = UUID().uuidString
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = try makeMultipart(boundary: boundary, text: text, audioData: audioData, image: image, timezone: timezone)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "API", code: (resp as? HTTPURLResponse)?.statusCode ?? -1, userInfo: ["body": String(data: data, encoding: .utf8) ?? ""]) 
        }
        // Response from edge function: { entry_id, image_path?, audio_path? }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let idStr = obj["entry_id"] as? String, let id = UUID(uuidString: idStr) {
            return id
        }
        throw URLError(.cannotParseResponse)
    }

    private func makeMultipart(boundary: String, text: String?, audioData: Data?, image: UIImage?, timezone: String) throws -> Data {
        var data = Data()
        func part(_ name: String, _ value: String) {
            data.append("--\(boundary)\r\n".data(using: .utf8)!)
            data.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            data.append("\(value)\r\n".data(using: .utf8)!)
        }
        part("timezone", timezone)
        if let t = text, !t.isEmpty { part("text", t) }
        if let raw = audioData {
            data.append("--\(boundary)\r\n".data(using: .utf8)!)
            data.append("Content-Disposition: form-data; name=\"audio\"; filename=\"voice.m4a\"\r\n".data(using: .utf8)!)
            data.append("Content-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
            data.append(raw); data.append("\r\n".data(using: .utf8)!)
        }
        if let img = image, let jpg = img.jpegData(compressionQuality: 0.92) {
            data.append("--\(boundary)\r\n".data(using: .utf8)!)
            data.append("Content-Disposition: form-data; name=\"image\"; filename=\"photo.jpg\"\r\n".data(using: .utf8)!)
            data.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
            data.append(jpg); data.append("\r\n".data(using: .utf8)!)
        }
        data.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return data
    }
}


