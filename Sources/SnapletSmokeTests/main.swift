import Foundation
import SnapletCore

@main
enum SnapletSmokeTests {
    static func main() throws {
        try verifyImageLibraryStore()
        try verifyPeerMessageRoundTrip()
        print("Snaplet smoke tests passed.")
    }

    private static func verifyImageLibraryStore() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let sourceRoot = fileManager.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)

        try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: temporaryRoot)
            try? fileManager.removeItem(at: sourceRoot)
        }

        let firstImage = sourceRoot.appending(path: "one.jpg")
        let secondImage = sourceRoot.appending(path: "two.jpg")
        let receivedImage = sourceRoot.appending(path: "received.temporary")
        try Data("one".utf8).write(to: firstImage)
        try Data("two".utf8).write(to: secondImage)
        try Data("three".utf8).write(to: receivedImage)

        let store = try ImageLibraryStore(rootDirectory: temporaryRoot)
        let importedAssets = try store.importImages(from: [firstImage])
        Thread.sleep(forTimeInterval: 0.02)
        _ = try store.importImages(from: [secondImage])
        Thread.sleep(forTimeInterval: 0.02)
        let uploadedAsset = try store.importReceivedFile(at: receivedImage, originalFilename: "three.png")
        let status = try store.libraryStatus(limit: 2)
        let randomAsset = try store.randomAsset()

        try assert(importedAssets.count == 1, "Expected first import call to return exactly one asset.")
        try assert(status.imageCount == 3, "Expected SQLite index to contain three images.")
        try assert(status.recentAssets.first?.originalFilename == "three.png", "Expected recent assets to be sorted newest first.")
        try assert(randomAsset != nil, "Expected random asset query to return a result.")
        try assert(fileManager.fileExists(atPath: importedAssets[0].fileURL(relativeTo: temporaryRoot).path), "Expected copied image to exist in local store.")
        try assert(uploadedAsset.originalFilename == "three.png", "Expected received uploads to preserve the provided original filename.")
        try assert(uploadedAsset.storedFilename.hasSuffix(".png"), "Expected received uploads to use the original filename extension when storing the file.")
    }

    private static func verifyPeerMessageRoundTrip() throws {
        let originalMessage = PeerMessage.transferReady(
            ResourceDescriptor(
                assetID: UUID(),
                resourceName: "asset.jpg",
                originalFilename: "sample.jpg",
                byteSize: 2_048
            ),
            purpose: .displayNow
        )
        let encoded = try originalMessage.encoded()
        let decoded = try PeerMessage.decoded(from: encoded)

        try assert(decoded == originalMessage, "Expected peer message JSON round-trip to preserve the payload.")
    }

    private static func assert(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if condition() {
            return
        }

        struct SmokeTestFailure: LocalizedError {
            let message: String

            var errorDescription: String? {
                message
            }
        }

        throw SmokeTestFailure(message: message)
    }
}
