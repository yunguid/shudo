import Foundation

public enum EntryStatus: String, Codable, Equatable {
    case queued
    case transcribing
    case analyzing
    case complete
    case failed
    case deleting

    public var isProcessing: Bool {
        switch self {
        case .queued, .transcribing, .analyzing:
            return true
        case .complete, .failed, .deleting:
            return false
        }
    }

    public var defaultMessage: String {
        switch self {
        case .queued: return "Queued"
        case .transcribing: return "Transcribing your note"
        case .analyzing: return "Estimating nutrition"
        case .complete: return "Ready"
        case .failed: return "Couldn’t process this meal"
        case .deleting: return "Deleting"
        }
    }
}

public struct Entry: Identifiable, Codable, Equatable {
    public var id: UUID
    public var createdAt: Date
    public var summary: String
    public var imageURL: URL?
    public var proteinG: Double
    public var carbsG: Double
    public var fatG: Double
    public var caloriesKcal: Double
    public var localDay: String?
    public var status: EntryStatus
    public var statusMessage: String?
    public var errorMessage: String?
    public var statusUpdatedAt: Date?
    public var processingAttempts: Int
    public var analysisPreview: String?

    public init(
        id: UUID,
        createdAt: Date,
        summary: String,
        imageURL: URL?,
        proteinG: Double,
        carbsG: Double,
        fatG: Double,
        caloriesKcal: Double,
        localDay: String? = nil,
        status: EntryStatus = .complete,
        statusMessage: String? = nil,
        errorMessage: String? = nil,
        statusUpdatedAt: Date? = nil,
        processingAttempts: Int = 0,
        analysisPreview: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.summary = summary
        self.imageURL = imageURL
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
        self.caloriesKcal = caloriesKcal
        self.localDay = localDay
        self.status = status
        self.statusMessage = statusMessage
        self.errorMessage = errorMessage
        self.statusUpdatedAt = statusUpdatedAt
        self.processingAttempts = processingAttempts
        self.analysisPreview = analysisPreview
    }

    public var displayStatusMessage: String {
        if status == .failed, processingAttempts >= 3 {
            return "Retry limit reached — log it again"
        }
        let trimmed = statusMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty { return trimmed }
        if status == .failed,
           let errorMessage,
           !errorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return errorMessage
        }
        return status.defaultMessage
    }

    public var canRetry: Bool {
        let message = statusMessage?.lowercased() ?? ""
        return status == .failed
            && processingAttempts < 3
            && !message.contains("delete")
    }

    public var canDelete: Bool {
        status == .complete || status == .failed
    }
}
