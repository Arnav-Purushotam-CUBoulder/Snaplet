import Foundation

public enum SnapletPeerConfiguration {
    public static let serviceType = "snpimgfeed"
    public static let bonjourService = "_snpimgfeed._tcp"
}

public enum PeerMessageKind: String, Codable, Sendable {
    case requestRandomImage
    case requestAsset
    case requestVideoCatalog
    case libraryStatus
    case videoCatalog
    case transferReady
    case uploadComplete
    case setFavorite
    case favoriteStatusUpdated
    case deleteAsset
    case assetDeleted
    case setVideoThumbnail
    case videoThumbnailUpdated
    case failure
}

public enum ImageRequestPurpose: String, Codable, Sendable {
    case displayNow
    case prefetch
}

public enum ImageSelectionScope: String, Codable, Sendable {
    case all
    case favorites
    case videos
    case favoriteVideos

    public var mediaType: MediaType {
        switch self {
        case .all, .favorites:
            .photo
        case .videos, .favoriteVideos:
            .video
        }
    }

    public var favoritesOnly: Bool {
        switch self {
        case .favorites, .favoriteVideos:
            true
        case .all, .videos:
            false
        }
    }

    public var isVideoScope: Bool {
        mediaType == .video
    }

    public var isPhotoScope: Bool {
        mediaType == .photo
    }

    public var tabTitle: String {
        switch self {
        case .all:
            "Photos"
        case .favorites:
            "Favorite Photos"
        case .videos:
            "Videos"
        case .favoriteVideos:
            "Favorite Videos"
        }
    }

    public var emptyStateTitle: String {
        switch self {
        case .all:
            "No Photos Yet"
        case .favorites:
            "No Favorite Photos"
        case .videos:
            "No Videos Yet"
        case .favoriteVideos:
            "No Favorite Videos"
        }
    }
}

public struct ResourceDescriptor: Codable, Equatable, Sendable {
    public let assetID: UUID
    public let mediaType: MediaType
    public let resourceName: String
    public let originalFilename: String
    public let byteSize: Int64
    public let isFavorite: Bool
    public let streamURL: URL?

    public init(
        assetID: UUID,
        mediaType: MediaType,
        resourceName: String,
        originalFilename: String,
        byteSize: Int64,
        isFavorite: Bool,
        streamURL: URL? = nil
    ) {
        self.assetID = assetID
        self.mediaType = mediaType
        self.resourceName = resourceName
        self.originalFilename = originalFilename
        self.byteSize = byteSize
        self.isFavorite = isFavorite
        self.streamURL = streamURL
    }
}

public enum VideoCatalogSort: String, Codable, Sendable, CaseIterable {
    case newest
    case durationAscending
    case durationDescending
}

public struct VideoCatalogItem: Identifiable, Codable, Equatable, Sendable {
    public let assetID: UUID
    public let originalFilename: String
    public let byteSize: Int64
    public let durationSeconds: Double?
    public let isFavorite: Bool
    public let importedAt: Date
    public let thumbnailURL: URL?

    public var id: UUID { assetID }

    public init(
        assetID: UUID,
        originalFilename: String,
        byteSize: Int64,
        durationSeconds: Double?,
        isFavorite: Bool,
        importedAt: Date,
        thumbnailURL: URL?
    ) {
        self.assetID = assetID
        self.originalFilename = originalFilename
        self.byteSize = byteSize
        self.durationSeconds = durationSeconds
        self.isFavorite = isFavorite
        self.importedAt = importedAt
        self.thumbnailURL = thumbnailURL
    }
}

public struct LibrarySummary: Codable, Equatable, Sendable {
    public let assetCount: Int
    public let photoCount: Int
    public let videoCount: Int
    public let favoritePhotoCount: Int
    public let favoriteVideoCount: Int

    public init(
        assetCount: Int,
        photoCount: Int,
        videoCount: Int,
        favoritePhotoCount: Int,
        favoriteVideoCount: Int
    ) {
        self.assetCount = assetCount
        self.photoCount = photoCount
        self.videoCount = videoCount
        self.favoritePhotoCount = favoritePhotoCount
        self.favoriteVideoCount = favoriteVideoCount
    }
}

public struct PeerMessage: Codable, Equatable, Sendable {
    public let kind: PeerMessageKind
    public let libraryCount: Int?
    public let librarySummary: LibrarySummary?
    public let resource: ResourceDescriptor?
    public let errorMessage: String?
    public let requestPurpose: ImageRequestPurpose?
    public let selectionScope: ImageSelectionScope?
    public let assetID: UUID?
    public let favoriteValue: Bool?
    public let videoCatalogItems: [VideoCatalogItem]?
    public let videoCatalogSort: VideoCatalogSort?
    public let thumbnailResourceName: String?

    public init(
        kind: PeerMessageKind,
        libraryCount: Int? = nil,
        librarySummary: LibrarySummary? = nil,
        resource: ResourceDescriptor? = nil,
        errorMessage: String? = nil,
        requestPurpose: ImageRequestPurpose? = nil,
        selectionScope: ImageSelectionScope? = nil,
        assetID: UUID? = nil,
        favoriteValue: Bool? = nil,
        videoCatalogItems: [VideoCatalogItem]? = nil,
        videoCatalogSort: VideoCatalogSort? = nil,
        thumbnailResourceName: String? = nil
    ) {
        self.kind = kind
        self.libraryCount = libraryCount
        self.librarySummary = librarySummary
        self.resource = resource
        self.errorMessage = errorMessage
        self.requestPurpose = requestPurpose
        self.selectionScope = selectionScope
        self.assetID = assetID
        self.favoriteValue = favoriteValue
        self.videoCatalogItems = videoCatalogItems
        self.videoCatalogSort = videoCatalogSort
        self.thumbnailResourceName = thumbnailResourceName
    }

    public static func requestRandomImage(
        purpose: ImageRequestPurpose,
        scope: ImageSelectionScope
    ) -> PeerMessage {
        PeerMessage(
            kind: .requestRandomImage,
            requestPurpose: purpose,
            selectionScope: scope
        )
    }

    public static func requestAsset(
        assetID: UUID,
        purpose: ImageRequestPurpose,
        scope: ImageSelectionScope
    ) -> PeerMessage {
        PeerMessage(
            kind: .requestAsset,
            requestPurpose: purpose,
            selectionScope: scope,
            assetID: assetID
        )
    }

    public static func requestVideoCatalog(scope: ImageSelectionScope, sort: VideoCatalogSort) -> PeerMessage {
        PeerMessage(kind: .requestVideoCatalog, selectionScope: scope, videoCatalogSort: sort)
    }

    public static func libraryStatus(count: Int) -> PeerMessage {
        PeerMessage(kind: .libraryStatus, libraryCount: count)
    }

    public static func libraryStatus(summary: LibrarySummary) -> PeerMessage {
        PeerMessage(kind: .libraryStatus, libraryCount: summary.assetCount, librarySummary: summary)
    }

    public static func videoCatalog(
        items: [VideoCatalogItem],
        scope: ImageSelectionScope,
        sort: VideoCatalogSort
    ) -> PeerMessage {
        PeerMessage(kind: .videoCatalog, selectionScope: scope, videoCatalogItems: items, videoCatalogSort: sort)
    }

    public static func transferReady(
        _ descriptor: ResourceDescriptor,
        purpose: ImageRequestPurpose,
        scope: ImageSelectionScope
    ) -> PeerMessage {
        PeerMessage(
            kind: .transferReady,
            resource: descriptor,
            requestPurpose: purpose,
            selectionScope: scope
        )
    }

    public static func uploadComplete(_ descriptor: ResourceDescriptor, count: Int) -> PeerMessage {
        PeerMessage(kind: .uploadComplete, libraryCount: count, resource: descriptor)
    }

    public static func setFavorite(assetID: UUID, isFavorite: Bool) -> PeerMessage {
        PeerMessage(kind: .setFavorite, assetID: assetID, favoriteValue: isFavorite)
    }

    public static func favoriteStatusUpdated(assetID: UUID, isFavorite: Bool) -> PeerMessage {
        PeerMessage(kind: .favoriteStatusUpdated, assetID: assetID, favoriteValue: isFavorite)
    }

    public static func deleteAsset(assetID: UUID) -> PeerMessage {
        PeerMessage(kind: .deleteAsset, assetID: assetID)
    }

    public static func setVideoThumbnail(assetID: UUID, resourceName: String) -> PeerMessage {
        PeerMessage(kind: .setVideoThumbnail, assetID: assetID, thumbnailResourceName: resourceName)
    }

    public static func videoThumbnailUpdated(assetID: UUID) -> PeerMessage {
        PeerMessage(kind: .videoThumbnailUpdated, assetID: assetID)
    }

    public static func assetDeleted(assetID: UUID, count: Int) -> PeerMessage {
        PeerMessage(kind: .assetDeleted, libraryCount: count, assetID: assetID)
    }

    public static func failure(_ message: String) -> PeerMessage {
        PeerMessage(kind: .failure, errorMessage: message)
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decoded(from data: Data) throws -> PeerMessage {
        try JSONDecoder().decode(PeerMessage.self, from: data)
    }
}
