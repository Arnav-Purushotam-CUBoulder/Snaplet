import Foundation

public struct LibraryStatus: Equatable, Sendable {
    public let imageCount: Int
    public let recentAssets: [ImageAsset]

    public init(imageCount: Int, recentAssets: [ImageAsset]) {
        self.imageCount = imageCount
        self.recentAssets = recentAssets
    }

    public var latestAsset: ImageAsset? {
        recentAssets.first
    }
}
