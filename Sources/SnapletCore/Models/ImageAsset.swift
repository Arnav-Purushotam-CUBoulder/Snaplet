import Foundation

public struct ImageAsset: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let originalFilename: String
    public let storedFilename: String
    public let relativePath: String
    public let byteSize: Int64
    public let isFavorite: Bool
    public let importedAt: Date

    public init(
        id: UUID,
        originalFilename: String,
        storedFilename: String,
        relativePath: String,
        byteSize: Int64,
        isFavorite: Bool,
        importedAt: Date
    ) {
        self.id = id
        self.originalFilename = originalFilename
        self.storedFilename = storedFilename
        self.relativePath = relativePath
        self.byteSize = byteSize
        self.isFavorite = isFavorite
        self.importedAt = importedAt
    }

    public func fileURL(relativeTo rootDirectory: URL) -> URL {
        rootDirectory.appending(path: relativePath)
    }
}
