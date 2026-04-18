import Darwin
import Foundation
import SnapletCore

@main
enum SnapletAdmin {
    private enum Command: String {
        case status
        case migrateReindex = "migrate-reindex"
        case setViewerDevice = "set-viewer-device"
        case benchmarkStorage = "benchmark-storage"
    }

    static func main() throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        let rootDirectory = try resolvedRootDirectory(arguments: &arguments)
        let command = Command(rawValue: arguments.first ?? Command.status.rawValue) ?? .status

        if arguments.isEmpty == false {
            arguments.removeFirst()
        }

        switch command {
        case .status:
            try printStatus(rootDirectory: rootDirectory)
        case .migrateReindex:
            try migrateAndReindex(rootDirectory: rootDirectory)
        case .setViewerDevice:
            try setViewerDevice(arguments: arguments, rootDirectory: rootDirectory)
        case .benchmarkStorage:
            try benchmarkStorage(rootDirectory: rootDirectory)
        }
    }

    private static func resolvedRootDirectory(arguments: inout [String]) throws -> URL {
        guard let rootFlagIndex = arguments.firstIndex(of: "--root") else {
            return try AppSupportPaths.hostRootDirectory()
        }

        let valueIndex = arguments.index(after: rootFlagIndex)
        guard valueIndex < arguments.endIndex else {
            throw UsageError(message: "Expected a path after --root.")
        }

        let rootPath = arguments[valueIndex]
        arguments.remove(at: valueIndex)
        arguments.remove(at: rootFlagIndex)
        return URL(fileURLWithPath: rootPath, isDirectory: true)
    }

    private static func printStatus(rootDirectory: URL) throws {
        let store = try ImageLibraryStore(rootDirectory: rootDirectory)
        let status = try store.libraryStatus(limit: 5)
        let metadata = try SnapletMetadataStore(rootDirectory: rootDirectory).load()

        print("Root: \(rootDirectory.path)")
        print("Assets: \(status.assetCount)")
        print("Photos: \(status.photoCount)")
        print("Videos: \(status.videoCount)")
        print("Favorite Photos: \(status.favoritePhotoCount)")
        print("Favorite Videos: \(status.favoriteVideoCount)")
        if let viewerDevice = metadata.viewerDevice {
            print("Viewer Device: \(viewerDevice.modelName)")
        }
    }

    private static func migrateAndReindex(rootDirectory: URL) throws {
        let store = try ImageLibraryStore(rootDirectory: rootDirectory)
        let summary = try store.migrateLegacyLibraryAndReindex()

        print("Root: \(rootDirectory.path)")
        if summary.migration.renamedLegacyDirectories.isEmpty == false {
            print("Renamed Directories: \(summary.migration.renamedLegacyDirectories.joined(separator: ", "))")
        }
        print("Moved Photos: \(summary.migration.movedPhotoFileCount)")
        print("Moved Videos: \(summary.migration.movedVideoFileCount)")
        print("Indexed Assets: \(summary.reindex.indexedAssetCount)")
        print("Indexed Photos: \(summary.reindex.indexedPhotoCount)")
        print("Indexed Videos: \(summary.reindex.indexedVideoCount)")
        print("Skipped Files: \(summary.reindex.skippedFileCount)")
    }

    private static func setViewerDevice(arguments: [String], rootDirectory: URL) throws {
        let modelName = arguments.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard modelName.isEmpty == false else {
            throw UsageError(message: "Provide a device model after set-viewer-device.")
        }

        let metadata = try SnapletMetadataStore(rootDirectory: rootDirectory).setViewerDeviceModel(modelName)
        print("Root: \(rootDirectory.path)")
        print("Viewer Device: \(metadata.viewerDevice?.modelName ?? modelName)")
    }

    private static func benchmarkStorage(rootDirectory: URL) throws {
        let store = try ImageLibraryStore(rootDirectory: rootDirectory)
        let photoAssets = try sampledAssets(from: store, scope: .all, limit: 60)
        let videoAssets = try sampledAssets(from: store, scope: .videos, limit: 8)

        let externalPhotoURLs = photoAssets.map { $0.fileURL(relativeTo: rootDirectory) }
        let externalVideoURLs = videoAssets.map { $0.fileURL(relativeTo: rootDirectory) }
        let internalCopyDirectory = FileManager.default.temporaryDirectory
            .appending(path: "snaplet-storage-benchmark-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: internalCopyDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: internalCopyDirectory)
        }

        let internalPhotoURLs = try copyAssetsToTemporaryDirectory(
            externalPhotoURLs,
            destinationDirectory: internalCopyDirectory
        )

        let externalPhotoSummary = try benchmarkReadMetrics(for: externalPhotoURLs)
        let internalPhotoSummary = try benchmarkReadMetrics(for: internalPhotoURLs)
        let externalVideoSummary = try benchmarkReadMetrics(for: externalVideoURLs, maximumBytesToRead: 8 * 1024 * 1024)

        print("Root: \(rootDirectory.path)")
        print("")
        print("Photo sample count: \(externalPhotoSummary.sampleCount)")
        print("Photo average size: \(formattedMegabytes(externalPhotoSummary.averageBytesRead))")
        print("External photo first-read latency: \(formattedMilliseconds(externalPhotoSummary.averageFirstReadLatencyMs)) avg, \(formattedMilliseconds(externalPhotoSummary.p95FirstReadLatencyMs)) p95")
        print("External photo uncached throughput: \(formattedThroughput(externalPhotoSummary.averageThroughputMBps)) avg")
        print("Internal photo first-read latency: \(formattedMilliseconds(internalPhotoSummary.averageFirstReadLatencyMs)) avg, \(formattedMilliseconds(internalPhotoSummary.p95FirstReadLatencyMs)) p95")
        print("Internal photo uncached throughput: \(formattedThroughput(internalPhotoSummary.averageThroughputMBps)) avg")
        print("")
        print("Video sample count: \(externalVideoSummary.sampleCount)")
        print("Video benchmark window: first 8 MB uncached read")
        print("Video average sampled bytes: \(formattedMegabytes(externalVideoSummary.averageBytesRead))")
        print("External video first-read latency: \(formattedMilliseconds(externalVideoSummary.averageFirstReadLatencyMs)) avg, \(formattedMilliseconds(externalVideoSummary.p95FirstReadLatencyMs)) p95")
        print("External video uncached throughput: \(formattedThroughput(externalVideoSummary.averageThroughputMBps)) avg")
    }

    private static func sampledAssets(
        from store: ImageLibraryStore,
        scope: ImageSelectionScope,
        limit: Int
    ) throws -> [ImageAsset] {
        guard limit > 0 else { return [] }

        var assets: [ImageAsset] = []
        var seenAssetIDs: Set<UUID> = []
        let targetAttempts = max(limit * 24, limit)

        for _ in 0..<targetAttempts {
            guard assets.count < limit else { break }
            guard let asset = try store.randomAsset(in: scope) else { break }
            guard seenAssetIDs.insert(asset.id).inserted else { continue }
            assets.append(asset)
        }

        if assets.count < limit {
            let fallbackAssets = try store.recentAssets(limit: limit * 2, mediaType: scope.mediaType)
            for asset in fallbackAssets {
                guard assets.count < limit else { break }
                guard seenAssetIDs.insert(asset.id).inserted else { continue }
                if scope.favoritesOnly, asset.isFavorite == false {
                    continue
                }
                assets.append(asset)
            }
        }

        return assets
    }

    private static func copyAssetsToTemporaryDirectory(
        _ sourceURLs: [URL],
        destinationDirectory: URL
    ) throws -> [URL] {
        var copiedURLs: [URL] = []
        for sourceURL in sourceURLs {
            let destinationURL = destinationDirectory.appending(path: "\(UUID().uuidString)-\(sourceURL.lastPathComponent)")
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            copiedURLs.append(destinationURL)
        }
        return copiedURLs
    }

    private static func benchmarkReadMetrics(
        for fileURLs: [URL],
        maximumBytesToRead: Int64? = nil
    ) throws -> ReadBenchmarkSummary {
        let measurements = try fileURLs.map { fileURL in
            try measureUncachedRead(at: fileURL, maximumBytesToRead: maximumBytesToRead)
        }
        return ReadBenchmarkSummary(measurements: measurements)
    }

    private static func measureUncachedRead(
        at fileURL: URL,
        maximumBytesToRead: Int64?
    ) throws -> ReadMeasurement {
        let fileDescriptor = open(fileURL.path, O_RDONLY)
        guard fileDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer {
            close(fileDescriptor)
        }

        _ = fcntl(fileDescriptor, F_NOCACHE, 1)

        let bufferSize = 256 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer {
            buffer.deallocate()
        }

        let start = DispatchTime.now().uptimeNanoseconds
        var firstReadLatencyMs: Double?
        var totalBytesRead: Int64 = 0

        while maximumBytesToRead == nil || totalBytesRead < maximumBytesToRead! {
            let remainingByteCount = maximumBytesToRead.map { max(Int($0 - totalBytesRead), 0) } ?? bufferSize
            let requestedByteCount = min(bufferSize, remainingByteCount)
            if requestedByteCount <= 0 {
                break
            }

            let bytesRead = Darwin.read(fileDescriptor, buffer, requestedByteCount)
            if bytesRead < 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if bytesRead == 0 {
                break
            }

            totalBytesRead += Int64(bytesRead)
            if firstReadLatencyMs == nil {
                let elapsedNs = DispatchTime.now().uptimeNanoseconds - start
                firstReadLatencyMs = Double(elapsedNs) / 1_000_000
            }
        }

        let elapsedNs = DispatchTime.now().uptimeNanoseconds - start
        let elapsedSeconds = max(Double(elapsedNs) / 1_000_000_000, 0.000_001)
        let throughputMBps = (Double(totalBytesRead) / 1_048_576) / elapsedSeconds

        return ReadMeasurement(
            firstReadLatencyMs: firstReadLatencyMs ?? 0,
            bytesRead: totalBytesRead,
            throughputMBps: throughputMBps
        )
    }

    private static func formattedMilliseconds(_ value: Double) -> String {
        String(format: "%.2f ms", value)
    }

    private static func formattedThroughput(_ value: Double) -> String {
        String(format: "%.1f MB/s", value)
    }

    private static func formattedMegabytes(_ bytes: Int64) -> String {
        String(format: "%.2f MB", Double(bytes) / 1_048_576)
    }
}

private struct UsageError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

private struct ReadMeasurement {
    let firstReadLatencyMs: Double
    let bytesRead: Int64
    let throughputMBps: Double
}

private struct ReadBenchmarkSummary {
    let sampleCount: Int
    let averageFirstReadLatencyMs: Double
    let p95FirstReadLatencyMs: Double
    let averageThroughputMBps: Double
    let averageBytesRead: Int64

    init(measurements: [ReadMeasurement]) {
        sampleCount = measurements.count

        guard measurements.isEmpty == false else {
            averageFirstReadLatencyMs = 0
            p95FirstReadLatencyMs = 0
            averageThroughputMBps = 0
            averageBytesRead = 0
            return
        }

        let sortedLatencies = measurements
            .map(\.firstReadLatencyMs)
            .sorted()
        let p95Index = min(Int(Double(sortedLatencies.count - 1) * 0.95), sortedLatencies.count - 1)

        averageFirstReadLatencyMs = measurements
            .map(\.firstReadLatencyMs)
            .reduce(0, +) / Double(measurements.count)
        p95FirstReadLatencyMs = sortedLatencies[p95Index]
        averageThroughputMBps = measurements
            .map(\.throughputMBps)
            .reduce(0, +) / Double(measurements.count)
        averageBytesRead = measurements
            .map(\.bytesRead)
            .reduce(0, +) / Int64(measurements.count)
    }
}
