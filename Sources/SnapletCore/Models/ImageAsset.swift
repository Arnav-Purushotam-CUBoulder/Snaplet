import Foundation

public enum MediaType: String, Codable, CaseIterable, Sendable {
    case photo
    case video

    public var directoryName: String {
        switch self {
        case .photo:
            "Photos"
        case .video:
            "Videos"
        }
    }

    public var singularDisplayName: String {
        switch self {
        case .photo:
            "photo"
        case .video:
            "video"
        }
    }

    public var pluralDisplayName: String {
        switch self {
        case .photo:
            "photos"
        case .video:
            "videos"
        }
    }

    public var systemImage: String {
        switch self {
        case .photo:
            "photo"
        case .video:
            "video"
        }
    }

    public static func mimeType(for fileURL: URL) -> String {
        mimeType(forPathExtension: fileURL.pathExtension)
    }

    public static func mimeType(forPathExtension pathExtension: String) -> String {
        let normalizedExtension = pathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return switch normalizedExtension {
        case "avif":
            "image/avif"
        case "bmp":
            "image/bmp"
        case "gif":
            "image/gif"
        case "heic":
            "image/heic"
        case "heif":
            "image/heif"
        case "jpeg", "jpg":
            "image/jpeg"
        case "png":
            "image/png"
        case "tif", "tiff":
            "image/tiff"
        case "webp":
            "image/webp"
        case "avi":
            "video/x-msvideo"
        case "m4v":
            "video/x-m4v"
        case "mkv":
            "video/x-matroska"
        case "mov":
            "video/quicktime"
        case "mp4":
            "video/mp4"
        case "mpeg", "mpg":
            "video/mpeg"
        case "webm":
            "video/webm"
        default:
            "application/octet-stream"
        }
    }

    public static func infer(from fileURL: URL) -> MediaType? {
        infer(fromPathExtension: fileURL.pathExtension)
    }

    public static func infer(fromPathExtension pathExtension: String) -> MediaType? {
        let normalizedExtension = pathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard normalizedExtension.isEmpty == false else {
            return nil
        }

        if photoExtensions.contains(normalizedExtension) {
            return .photo
        }

        if videoExtensions.contains(normalizedExtension) {
            return .video
        }

        return nil
    }

    private static let photoExtensions: Set<String> = [
        "avif",
        "bmp",
        "gif",
        "heic",
        "heif",
        "jpeg",
        "jpg",
        "png",
        "tif",
        "tiff",
        "webp"
    ]

    private static let videoExtensions: Set<String> = [
        "avi",
        "m4v",
        "mkv",
        "mov",
        "mp4",
        "mpeg",
        "mpg",
        "webm"
    ]
}

public struct ImageAsset: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let mediaType: MediaType
    public let originalFilename: String
    public let storedFilename: String
    public let relativePath: String
    public let thumbnailRelativePath: String?
    public let byteSize: Int64
    public let durationSeconds: Double?
    public let isFavorite: Bool
    public let importedAt: Date

    public init(
        id: UUID,
        mediaType: MediaType,
        originalFilename: String,
        storedFilename: String,
        relativePath: String,
        thumbnailRelativePath: String? = nil,
        byteSize: Int64,
        durationSeconds: Double? = nil,
        isFavorite: Bool,
        importedAt: Date
    ) {
        self.id = id
        self.mediaType = mediaType
        self.originalFilename = originalFilename
        self.storedFilename = storedFilename
        self.relativePath = relativePath
        self.thumbnailRelativePath = thumbnailRelativePath
        self.byteSize = byteSize
        self.durationSeconds = durationSeconds
        self.isFavorite = isFavorite
        self.importedAt = importedAt
    }

    public var isPhoto: Bool {
        mediaType == .photo
    }

    public var isVideo: Bool {
        mediaType == .video
    }

    public func fileURL(relativeTo rootDirectory: URL) -> URL {
        rootDirectory.appending(path: relativePath)
    }

    public func thumbnailURL(relativeTo rootDirectory: URL) -> URL? {
        thumbnailRelativePath.map { rootDirectory.appending(path: $0) }
    }
}
