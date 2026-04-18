import Foundation

public struct LibraryStatus: Equatable, Sendable {
    public let assetCount: Int
    public let photoCount: Int
    public let videoCount: Int
    public let favoritePhotoCount: Int
    public let favoriteVideoCount: Int
    public let recentAssets: [ImageAsset]

    public init(
        assetCount: Int,
        photoCount: Int,
        videoCount: Int,
        favoritePhotoCount: Int,
        favoriteVideoCount: Int,
        recentAssets: [ImageAsset]
    ) {
        self.assetCount = assetCount
        self.photoCount = photoCount
        self.videoCount = videoCount
        self.favoritePhotoCount = favoritePhotoCount
        self.favoriteVideoCount = favoriteVideoCount
        self.recentAssets = recentAssets
    }

    public var imageCount: Int {
        photoCount
    }

    public var latestAsset: ImageAsset? {
        recentAssets.first
    }
}
