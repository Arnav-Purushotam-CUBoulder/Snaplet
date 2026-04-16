import Foundation

public enum SnapletPeerConfiguration {
    public static let serviceType = "snpimgfeed"
    public static let bonjourService = "_snpimgfeed._tcp"
}

public enum PeerMessageKind: String, Codable, Sendable {
    case requestRandomImage
    case libraryStatus
    case transferReady
    case uploadComplete
    case failure
}

public enum ImageRequestPurpose: String, Codable, Sendable {
    case displayNow
    case prefetch
}

public struct ResourceDescriptor: Codable, Equatable, Sendable {
    public let assetID: UUID
    public let resourceName: String
    public let originalFilename: String
    public let byteSize: Int64

    public init(
        assetID: UUID,
        resourceName: String,
        originalFilename: String,
        byteSize: Int64
    ) {
        self.assetID = assetID
        self.resourceName = resourceName
        self.originalFilename = originalFilename
        self.byteSize = byteSize
    }
}

public struct PeerMessage: Codable, Equatable, Sendable {
    public let kind: PeerMessageKind
    public let libraryCount: Int?
    public let resource: ResourceDescriptor?
    public let errorMessage: String?
    public let requestPurpose: ImageRequestPurpose?

    public init(
        kind: PeerMessageKind,
        libraryCount: Int? = nil,
        resource: ResourceDescriptor? = nil,
        errorMessage: String? = nil,
        requestPurpose: ImageRequestPurpose? = nil
    ) {
        self.kind = kind
        self.libraryCount = libraryCount
        self.resource = resource
        self.errorMessage = errorMessage
        self.requestPurpose = requestPurpose
    }

    public static func requestRandomImage(purpose: ImageRequestPurpose) -> PeerMessage {
        PeerMessage(kind: .requestRandomImage, requestPurpose: purpose)
    }

    public static func libraryStatus(count: Int) -> PeerMessage {
        PeerMessage(kind: .libraryStatus, libraryCount: count)
    }

    public static func transferReady(_ descriptor: ResourceDescriptor, purpose: ImageRequestPurpose) -> PeerMessage {
        PeerMessage(kind: .transferReady, resource: descriptor, requestPurpose: purpose)
    }

    public static func uploadComplete(_ descriptor: ResourceDescriptor, count: Int) -> PeerMessage {
        PeerMessage(kind: .uploadComplete, libraryCount: count, resource: descriptor)
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
