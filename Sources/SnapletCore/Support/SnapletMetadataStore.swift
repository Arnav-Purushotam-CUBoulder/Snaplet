import Foundation

public struct ViewerDeviceProfile: Codable, Equatable, Sendable {
    public let modelName: String
    public let updatedAt: Date

    public init(modelName: String, updatedAt: Date = Date()) {
        self.modelName = modelName
        self.updatedAt = updatedAt
    }
}

public struct SnapletMetadata: Codable, Equatable, Sendable {
    public var viewerDevice: ViewerDeviceProfile?

    public init(viewerDevice: ViewerDeviceProfile? = nil) {
        self.viewerDevice = viewerDevice
    }
}

public final class SnapletMetadataStore: @unchecked Sendable {
    public let fileURL: URL

    private let fileManager: FileManager
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let lock = NSRecursiveLock()

    public init(rootDirectory: URL, fileManager: FileManager = .default) {
        self.fileURL = rootDirectory.appending(path: "snaplet-metadata.json")
        self.fileManager = fileManager
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public func load() throws -> SnapletMetadata {
        try withLock {
            guard fileManager.fileExists(atPath: fileURL.path) else {
                return SnapletMetadata()
            }

            let data = try Data(contentsOf: fileURL)
            return try decoder.decode(SnapletMetadata.self, from: data)
        }
    }

    @discardableResult
    public func save(_ metadata: SnapletMetadata) throws -> SnapletMetadata {
        try withLock {
            let data = try encoder.encode(metadata)
            let directoryURL = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            return metadata
        }
    }

    @discardableResult
    public func update(_ update: (inout SnapletMetadata) -> Void) throws -> SnapletMetadata {
        try withLock {
            var metadata = try load()
            update(&metadata)
            return try save(metadata)
        }
    }

    @discardableResult
    public func setViewerDeviceModel(_ modelName: String) throws -> SnapletMetadata {
        try update { metadata in
            metadata.viewerDevice = ViewerDeviceProfile(modelName: modelName)
        }
    }

    private func withLock<T>(_ operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
