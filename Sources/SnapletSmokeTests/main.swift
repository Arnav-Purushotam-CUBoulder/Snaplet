import Foundation
import SnapletCore

@main
enum SnapletSmokeTests {
    static func main() throws {
        try verifyImageLibraryStore()
        try verifyReindexHandlesDuplicateStoredFilenames()
        try verifyPeerMessageRoundTrip()
        try verifyMediaStreamingServer()
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
        let favoritedAsset = try store.updateFavoriteStatus(assetID: uploadedAsset.id, isFavorite: true)
        let status = try store.libraryStatus(limit: 2)
        let randomAsset = try store.randomAsset()
        let favoriteRandomAsset = try store.randomAsset(favoritesOnly: true)

        try assert(importedAssets.count == 1, "Expected first import call to return exactly one asset.")
        try assert(status.imageCount == 3, "Expected SQLite index to contain three images.")
        try assert(status.recentAssets.first?.originalFilename == "three.png", "Expected recent assets to be sorted newest first.")
        try assert(randomAsset != nil, "Expected random asset query to return a result.")
        try assert(favoriteRandomAsset?.id == uploadedAsset.id, "Expected favorite-only random query to return the favorited asset.")
        try assert(fileManager.fileExists(atPath: importedAssets[0].fileURL(relativeTo: temporaryRoot).path), "Expected copied image to exist in local store.")
        try assert(uploadedAsset.originalFilename == "three.png", "Expected received uploads to preserve the provided original filename.")
        try assert(uploadedAsset.storedFilename.hasSuffix(".png"), "Expected received uploads to use the original filename extension when storing the file.")
        try assert(favoritedAsset?.isFavorite == true, "Expected favorite update to persist in SQLite.")
    }

    private static func verifyReindexHandlesDuplicateStoredFilenames() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let sourceRoot = fileManager.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)

        try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: temporaryRoot)
            try? fileManager.removeItem(at: sourceRoot)
        }

        let sourceVideo = sourceRoot.appending(path: "clip.mp4")
        try Data("video-one".utf8).write(to: sourceVideo)

        let store = try ImageLibraryStore(rootDirectory: temporaryRoot)
        let importedAssets = try store.importAssets(from: [sourceVideo])
        guard let importedVideo = importedAssets.first else {
            throw SmokeTestFailure(message: "Expected video import to create an indexed asset.")
        }

        let nestedVideoDirectory = temporaryRoot
            .appending(path: "Videos", directoryHint: .isDirectory)
            .appending(path: "nested", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: nestedVideoDirectory, withIntermediateDirectories: true)

        let duplicateStoredFilenameURL = nestedVideoDirectory.appending(path: importedVideo.storedFilename)
        try Data("video-two".utf8).write(to: duplicateStoredFilenameURL)

        let summary = try store.reindexLibrary()
        let status = try store.libraryStatus(limit: 10)
        let indexedVideos = try store.recentAssets(limit: 10, mediaType: .video)

        try assert(summary.indexedVideoCount == 2, "Expected reindex to keep both duplicate video filenames.")
        try assert(status.videoCount == 2, "Expected SQLite status to report both duplicate video filenames.")
        try assert(Set(indexedVideos.map(\.id)).count == 2, "Expected duplicate stored filenames to keep distinct asset IDs.")
    }

    private static func verifyPeerMessageRoundTrip() throws {
        let originalMessage = PeerMessage.transferReady(
            ResourceDescriptor(
                assetID: UUID(),
                mediaType: .photo,
                resourceName: "asset.jpg",
                originalFilename: "sample.jpg",
                byteSize: 2_048,
                isFavorite: true
            ),
            purpose: .displayNow,
            scope: .favorites
        )
        let encoded = try originalMessage.encoded()
        let decoded = try PeerMessage.decoded(from: encoded)

        try assert(decoded == originalMessage, "Expected peer message JSON round-trip to preserve the payload.")
    }

    private static func verifyMediaStreamingServer() throws {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: temporaryDirectory)
        }

        let videoURL = temporaryDirectory.appending(path: "sample.mp4")
        let sourceBytes = Data((0..<64).map { UInt8($0) })
        try sourceBytes.write(to: videoURL)

        let server = MediaStreamingServer()
        server.start()
        defer {
            server.stop()
        }

        var streamURL: URL?
        for _ in 0..<40 {
            streamURL = server.registerVideo(at: videoURL, byteSize: Int64(sourceBytes.count))
            if streamURL != nil {
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        guard let streamURL else {
            throw SmokeTestFailure(message: "Expected media streaming server to publish a usable URL.")
        }

        var request = URLRequest(url: streamURL)
        request.setValue("bytes=4-7", forHTTPHeaderField: "Range")

        let semaphore = DispatchSemaphore(value: 0)
        let resultBox = StreamingRequestResultBox()

        URLSession.shared.dataTask(with: request) { data, response, error in
            resultBox.data = data
            resultBox.response = response
            resultBox.error = error
            semaphore.signal()
        }
        .resume()

        semaphore.wait()

        try assert(resultBox.error == nil, "Expected media streaming request to finish without an error.")
        let httpResponse = try assertResponse(resultBox.response, expectedStatusCode: 206)
        try assert(
            httpResponse.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes",
            "Expected media streaming response to advertise byte ranges."
        )
        try assert(resultBox.data == Data([4, 5, 6, 7]), "Expected media streaming range response to match the requested bytes.")
    }

    private static func assert(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if condition() {
            return
        }

        throw SmokeTestFailure(message: message)
    }

    private static func assertResponse(_ response: URLResponse?, expectedStatusCode: Int) throws -> HTTPURLResponse {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SmokeTestFailure(message: "Expected an HTTP response from the media streaming server.")
        }

        guard httpResponse.statusCode == expectedStatusCode else {
            throw SmokeTestFailure(
                message: "Expected HTTP \(expectedStatusCode) from the media streaming server but received \(httpResponse.statusCode)."
            )
        }

        return httpResponse
    }
}

private struct SmokeTestFailure: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

private final class StreamingRequestResultBox: @unchecked Sendable {
    var data: Data?
    var response: URLResponse?
    var error: Error?
}
