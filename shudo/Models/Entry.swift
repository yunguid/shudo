import Foundation

public struct Entry: Identifiable, Codable, Equatable {
    public var id: UUID
    public var createdAt: Date
    public var summary: String
    public var imageURL: URL?
    public var proteinG: Double
    public var carbsG: Double
    public var fatG: Double
    public var caloriesKcal: Double
}


