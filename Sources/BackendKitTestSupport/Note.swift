import Foundation

// MARK: - Note

/// The Codable fixture model the SQLRepository tests round-trip.
public struct Note: Codable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let count: Int

    public init(id: UUID, title: String, count: Int) {
        self.id = id
        self.title = title
        self.count = count
    }
}
