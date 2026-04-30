import AVFoundation
import Foundation
import ImageIO
import SQLite3
import UniformTypeIdentifiers

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum ImageLibraryStoreError: LocalizedError {
    case failedToOpenDatabase(String)
    case failedToPrepareStatement(String)
    case failedToExecuteStatement(String)
    case failedToCopyFile(String)
    case failedToMoveFile(String)
    case failedToDeleteFile(String)
    case failedToReadAttributes(String)
    case unsupportedMediaFile(String)
    case assetNotFound(UUID)

    public var errorDescription: String? {
        switch self {
        case let .failedToOpenDatabase(message):
            "Failed to open SQLite database: \(message)"
        case let .failedToPrepareStatement(message):
            "Failed to prepare SQLite statement: \(message)"
        case let .failedToExecuteStatement(message):
            "Failed to execute SQLite statement: \(message)"
        case let .failedToCopyFile(message):
            "Failed to copy media into the local store: \(message)"
        case let .failedToMoveFile(message):
            "Failed to move media inside the local store: \(message)"
        case let .failedToDeleteFile(message):
            "Failed to delete media from the local store: \(message)"
        case let .failedToReadAttributes(message):
            "Failed to read file attributes: \(message)"
        case let .unsupportedMediaFile(filename):
            "Unsupported media file: \(filename)"
        case let .assetNotFound(assetID):
            "Asset not found: \(assetID.uuidString)"
        }
    }
}

public struct MediaLibraryMigrationSummary: Equatable, Sendable {
    public let renamedLegacyDirectories: [String]
    public let movedPhotoFileCount: Int
    public let movedVideoFileCount: Int

    public init(
        renamedLegacyDirectories: [String],
        movedPhotoFileCount: Int,
        movedVideoFileCount: Int
    ) {
        self.renamedLegacyDirectories = renamedLegacyDirectories
        self.movedPhotoFileCount = movedPhotoFileCount
        self.movedVideoFileCount = movedVideoFileCount
    }
}

public struct MediaLibraryReindexSummary: Equatable, Sendable {
    public let indexedAssetCount: Int
    public let indexedPhotoCount: Int
    public let indexedVideoCount: Int
    public let skippedFileCount: Int

    public init(
        indexedAssetCount: Int,
        indexedPhotoCount: Int,
        indexedVideoCount: Int,
        skippedFileCount: Int
    ) {
        self.indexedAssetCount = indexedAssetCount
        self.indexedPhotoCount = indexedPhotoCount
        self.indexedVideoCount = indexedVideoCount
        self.skippedFileCount = skippedFileCount
    }
}

public struct MediaLibraryMaintenanceSummary: Equatable, Sendable {
    public let migration: MediaLibraryMigrationSummary
    public let reindex: MediaLibraryReindexSummary

    public init(migration: MediaLibraryMigrationSummary, reindex: MediaLibraryReindexSummary) {
        self.migration = migration
        self.reindex = reindex
    }
}

private struct IndexedAssetSnapshot {
    let id: UUID
    let originalFilename: String
    let storedFilename: String
    let relativePath: String
    let thumbnailRelativePath: String?
    let byteSize: Int64
    let durationSeconds: Double?
    let mediaType: MediaType
    let isFavorite: Bool
    let importedAt: Date
}

private struct IndexedAssetLookup {
    var byRelativePath: [String: IndexedAssetSnapshot]
    var byStoredFilename: [String: [IndexedAssetSnapshot]]
}

private struct LibraryCountSnapshot {
    let assetCount: Int
    let photoCount: Int
    let videoCount: Int
    let favoritePhotoCount: Int
    let favoriteVideoCount: Int
}

public final class ImageLibraryStore: @unchecked Sendable {
    public let rootDirectory: URL
    public let photosDirectory: URL
    public let videosDirectory: URL
    public let imagesDirectory: URL
    public let thumbnailsDirectory: URL
    public let databaseURL: URL

    private let fileManager: FileManager
    private let lock = NSRecursiveLock()
    private var database: OpaquePointer?

    public init(rootDirectory: URL, fileManager: FileManager = .default) throws {
        self.rootDirectory = rootDirectory
        self.photosDirectory = rootDirectory.appending(path: MediaType.photo.directoryName, directoryHint: .isDirectory)
        self.videosDirectory = rootDirectory.appending(path: MediaType.video.directoryName, directoryHint: .isDirectory)
        self.imagesDirectory = photosDirectory
        self.thumbnailsDirectory = rootDirectory.appending(path: "Thumbnails", directoryHint: .isDirectory)
        self.databaseURL = rootDirectory.appending(path: "snaplet.sqlite")
        self.fileManager = fileManager

        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)

        self.database = try Self.openDatabase(at: databaseURL)
        try Self.configureDatabase(database)
        try Self.execute(
            """
            CREATE TABLE IF NOT EXISTS images (
                id TEXT PRIMARY KEY NOT NULL,
                media_type TEXT NOT NULL DEFAULT 'photo',
                original_filename TEXT NOT NULL,
                stored_filename TEXT NOT NULL,
                relative_path TEXT NOT NULL,
                thumbnail_relative_path TEXT,
                byte_size INTEGER NOT NULL,
                duration_seconds REAL,
                imported_at REAL NOT NULL,
                is_favorite INTEGER NOT NULL DEFAULT 0
            );
            """,
            in: database
        )
        try Self.ensureFavoriteColumn(in: database)
        try Self.ensureMediaTypeColumn(in: database)
        try Self.ensureThumbnailRelativePathColumn(in: database)
        try Self.ensureDurationSecondsColumn(in: database)
        try Self.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_images_imported_at
            ON images(imported_at DESC);
            """,
            in: database
        )
        try Self.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_images_is_favorite
            ON images(is_favorite, imported_at DESC);
            """,
            in: database
        )
        try Self.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_images_media_type_imported_at
            ON images(media_type, imported_at DESC);
            """,
            in: database
        )
        try Self.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_images_media_type_is_favorite_imported_at
            ON images(media_type, is_favorite, imported_at DESC);
            """,
            in: database
        )
        try Self.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_images_stored_filename
            ON images(stored_filename);
            """,
            in: database
        )

        _ = try migrateLegacyLibraryLayout()
        try fileManager.createDirectory(at: photosDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: videosDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: thumbnailsDirectory, withIntermediateDirectories: true)
    }

    deinit {
        guard let database else { return }
        sqlite3_close(database)
    }

    public func importImages(from externalURLs: [URL]) throws -> [ImageAsset] {
        try withLock {
            try externalURLs.compactMap { externalURL in
                let asset = try importAsset(from: externalURL, originalFilenameOverride: nil, mediaType: nil)
                return asset.mediaType == .photo ? asset : nil
            }
        }
    }

    public func importAssets(from externalURLs: [URL]) throws -> [ImageAsset] {
        try withLock {
            try externalURLs.map { externalURL in
                try importAsset(from: externalURL, originalFilenameOverride: nil, mediaType: nil)
            }
        }
    }

    public func importReceivedFile(
        at localURL: URL,
        originalFilename: String,
        mediaType: MediaType? = nil
    ) throws -> ImageAsset {
        try withLock {
            try importAsset(from: localURL, originalFilenameOverride: originalFilename, mediaType: mediaType)
        }
    }

    public func randomAsset(favoritesOnly: Bool = false) throws -> ImageAsset? {
        try randomAsset(in: favoritesOnly ? .favorites : .all)
    }

    public func randomAsset(in scope: ImageSelectionScope) throws -> ImageAsset? {
        try withLock {
            let matchingAssetCount = try assetCountLocked(in: scope)
            guard matchingAssetCount > 0 else {
                return nil
            }

            let randomOffset = Int.random(in: 0..<matchingAssetCount)
            let sql = scope.favoritesOnly
                ? """
                SELECT id, media_type, original_filename, stored_filename, relative_path, thumbnail_relative_path, byte_size, duration_seconds, imported_at, is_favorite
                FROM images
                WHERE media_type = ? AND is_favorite = 1
                ORDER BY imported_at DESC
                LIMIT 1 OFFSET ?;
                """
                : """
                SELECT id, media_type, original_filename, stored_filename, relative_path, thumbnail_relative_path, byte_size, duration_seconds, imported_at, is_favorite
                FROM images
                WHERE media_type = ?
                ORDER BY imported_at DESC
                LIMIT 1 OFFSET ?;
                """

            let statement = try Self.prepare(sql, in: database)
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, scope.mediaType.rawValue, -1, sqliteTransient)
            sqlite3_bind_int64(statement, 2, sqlite3_int64(randomOffset))

            guard sqlite3_step(statement) == SQLITE_ROW else {
                return nil
            }

            return try Self.makeAsset(from: statement)
        }
    }

    public func recentAssets(limit: Int = 30) throws -> [ImageAsset] {
        try withLock {
            try recentAssetsLocked(limit: limit, mediaType: nil)
        }
    }

    public func recentAssets(limit: Int = 30, mediaType: MediaType?) throws -> [ImageAsset] {
        try withLock {
            try recentAssetsLocked(limit: limit, mediaType: mediaType)
        }
    }

    public func videoCatalogAssets(
        in scope: ImageSelectionScope,
        sort: VideoCatalogSort,
        limit: Int = 500
    ) throws -> [ImageAsset] {
        try withLock {
            let normalizedScope: ImageSelectionScope = scope.favoritesOnly ? .favoriteVideos : .videos
            try backfillMissingVideoDurationsLocked()
            let sql: String
            switch sort {
            case .newest:
                sql = normalizedScope.favoritesOnly
                    ? """
                    SELECT id, media_type, original_filename, stored_filename, relative_path, thumbnail_relative_path, byte_size, duration_seconds, imported_at, is_favorite
                    FROM images
                    WHERE media_type = 'video' AND is_favorite = 1
                    ORDER BY imported_at DESC
                    LIMIT ?;
                    """
                    : """
                    SELECT id, media_type, original_filename, stored_filename, relative_path, thumbnail_relative_path, byte_size, duration_seconds, imported_at, is_favorite
                    FROM images
                    WHERE media_type = 'video'
                    ORDER BY imported_at DESC
                    LIMIT ?;
                    """
            case .durationAscending:
                sql = normalizedScope.favoritesOnly
                    ? """
                    SELECT id, media_type, original_filename, stored_filename, relative_path, thumbnail_relative_path, byte_size, duration_seconds, imported_at, is_favorite
                    FROM images
                    WHERE media_type = 'video' AND is_favorite = 1
                    ORDER BY duration_seconds IS NULL, duration_seconds ASC, imported_at DESC
                    LIMIT ?;
                    """
                    : """
                    SELECT id, media_type, original_filename, stored_filename, relative_path, thumbnail_relative_path, byte_size, duration_seconds, imported_at, is_favorite
                    FROM images
                    WHERE media_type = 'video'
                    ORDER BY duration_seconds IS NULL, duration_seconds ASC, imported_at DESC
                    LIMIT ?;
                    """
            case .durationDescending:
                sql = normalizedScope.favoritesOnly
                    ? """
                    SELECT id, media_type, original_filename, stored_filename, relative_path, thumbnail_relative_path, byte_size, duration_seconds, imported_at, is_favorite
                    FROM images
                    WHERE media_type = 'video' AND is_favorite = 1
                    ORDER BY duration_seconds IS NULL, duration_seconds DESC, imported_at DESC
                    LIMIT ?;
                    """
                    : """
                    SELECT id, media_type, original_filename, stored_filename, relative_path, thumbnail_relative_path, byte_size, duration_seconds, imported_at, is_favorite
                    FROM images
                    WHERE media_type = 'video'
                    ORDER BY duration_seconds IS NULL, duration_seconds DESC, imported_at DESC
                    LIMIT ?;
                    """
            }

            let statement = try Self.prepare(sql, in: database)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(limit))

            var assets: [ImageAsset] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                assets.append(try Self.makeAsset(from: statement))
            }
            return assets
        }
    }

    public func setVideoThumbnail(assetID: UUID, sourceURL: URL, originalFilename: String) throws -> ImageAsset {
        try withLock {
            guard let asset = try assetLocked(withID: assetID), asset.mediaType == .video else {
                throw ImageLibraryStoreError.assetNotFound(assetID)
            }

            let normalizedExtension = URL(fileURLWithPath: originalFilename).pathExtension.lowercased()
            let storedFilename = normalizedExtension.isEmpty
                ? "\(assetID.uuidString)-thumbnail"
                : "\(assetID.uuidString)-thumbnail.\(normalizedExtension)"
            let destinationURL = thumbnailsDirectory.appending(path: storedFilename)

            do {
                try fileManager.createDirectory(at: thumbnailsDirectory, withIntermediateDirectories: true)
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
            } catch {
                throw ImageLibraryStoreError.failedToCopyFile(error.localizedDescription)
            }

            let thumbnailRelativePath = "Thumbnails/\(storedFilename)"
            let statement = try Self.prepare(
                """
                UPDATE images
                SET thumbnail_relative_path = ?
                WHERE id = ? AND media_type = 'video';
                """,
                in: database
            )
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, thumbnailRelativePath, -1, sqliteTransient)
            sqlite3_bind_text(statement, 2, assetID.uuidString, -1, sqliteTransient)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw ImageLibraryStoreError.failedToExecuteStatement(Self.lastErrorMessage(in: database))
            }

            if let previousThumbnailURL = asset.thumbnailURL(relativeTo: rootDirectory),
               previousThumbnailURL.standardizedFileURL != destinationURL.standardizedFileURL {
                try? fileManager.removeItem(at: previousThumbnailURL)
            }

            guard let updatedAsset = try assetLocked(withID: assetID) else {
                throw ImageLibraryStoreError.assetNotFound(assetID)
            }
            return updatedAsset
        }
    }

    public func thumbnailURL(forVideoAsset asset: ImageAsset) throws -> URL? {
        try withLock {
            guard asset.mediaType == .video else {
                return nil
            }

            if let thumbnailURL = asset.thumbnailURL(relativeTo: rootDirectory),
               fileManager.fileExists(atPath: thumbnailURL.path) {
                return thumbnailURL
            }

            let destinationURL = thumbnailsDirectory.appending(path: "\(asset.id.uuidString)-thumbnail.jpg")
            if fileManager.fileExists(atPath: destinationURL.path) == false {
                guard let thumbnailImage = try makeVideoThumbnailImage(for: asset) else {
                    return nil
                }
                try writeJPEGThumbnail(thumbnailImage, to: destinationURL)
            }

            let thumbnailRelativePath = "Thumbnails/\(destinationURL.lastPathComponent)"
            let statement = try Self.prepare(
                """
                UPDATE images
                SET thumbnail_relative_path = ?
                WHERE id = ? AND media_type = 'video';
                """,
                in: database
            )
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, thumbnailRelativePath, -1, sqliteTransient)
            sqlite3_bind_text(statement, 2, asset.id.uuidString, -1, sqliteTransient)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw ImageLibraryStoreError.failedToExecuteStatement(Self.lastErrorMessage(in: database))
            }

            return destinationURL
        }
    }

    public func libraryStatus(limit: Int = 30) throws -> LibraryStatus {
        try withLock {
            let counts = try libraryCountsLocked()
            return LibraryStatus(
                assetCount: counts.assetCount,
                photoCount: counts.photoCount,
                videoCount: counts.videoCount,
                favoritePhotoCount: counts.favoritePhotoCount,
                favoriteVideoCount: counts.favoriteVideoCount,
                recentAssets: try recentAssetsLocked(limit: limit, mediaType: nil)
            )
        }
    }

    public func assetCount() throws -> Int {
        try withLock {
            try assetCountLocked()
        }
    }

    public func assetCount(in scope: ImageSelectionScope) throws -> Int {
        try withLock {
            try assetCountLocked(in: scope)
        }
    }

    public func asset(withID assetID: UUID) throws -> ImageAsset? {
        try withLock {
            try assetLocked(withID: assetID)
        }
    }

    public func updateFavoriteStatus(assetID: UUID, isFavorite: Bool) throws -> ImageAsset? {
        try withLock {
            guard try assetLocked(withID: assetID) != nil else {
                return nil
            }

            let statement = try Self.prepare(
                """
                UPDATE images
                SET is_favorite = ?
                WHERE id = ?;
                """,
                in: database
            )
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_int(statement, 1, isFavorite ? 1 : 0)
            sqlite3_bind_text(statement, 2, assetID.uuidString, -1, sqliteTransient)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw ImageLibraryStoreError.failedToExecuteStatement(Self.lastErrorMessage(in: database))
            }

            return try assetLocked(withID: assetID)
        }
    }

    public func deleteAsset(assetID: UUID) throws -> ImageAsset? {
        try withLock {
            guard let asset = try assetLocked(withID: assetID) else {
                return nil
            }

            let sourceURL = asset.fileURL(relativeTo: rootDirectory)
            let stagingDirectory = asset.mediaType == .photo ? photosDirectory : videosDirectory
            let stagedRemovalURL = stagingDirectory.appending(path: ".snaplet-delete-\(UUID().uuidString)-\(asset.storedFilename)")

            if fileManager.fileExists(atPath: sourceURL.path) {
                do {
                    if fileManager.fileExists(atPath: stagedRemovalURL.path) {
                        try fileManager.removeItem(at: stagedRemovalURL)
                    }
                    try fileManager.moveItem(at: sourceURL, to: stagedRemovalURL)
                } catch {
                    throw ImageLibraryStoreError.failedToDeleteFile(error.localizedDescription)
                }
            }

            do {
                try Self.execute("BEGIN IMMEDIATE TRANSACTION;", in: database)

                let statement = try Self.prepare(
                    """
                    DELETE FROM images
                    WHERE id = ?;
                    """,
                    in: database
                )
                defer { sqlite3_finalize(statement) }

                sqlite3_bind_text(statement, 1, assetID.uuidString, -1, sqliteTransient)

                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw ImageLibraryStoreError.failedToExecuteStatement(Self.lastErrorMessage(in: database))
                }

                try Self.execute("COMMIT;", in: database)
            } catch {
                try? Self.execute("ROLLBACK;", in: database)

                if fileManager.fileExists(atPath: stagedRemovalURL.path), !fileManager.fileExists(atPath: sourceURL.path) {
                    try? fileManager.moveItem(at: stagedRemovalURL, to: sourceURL)
                }
                throw error
            }

            if fileManager.fileExists(atPath: stagedRemovalURL.path) {
                do {
                    try fileManager.removeItem(at: stagedRemovalURL)
                } catch {
                    throw ImageLibraryStoreError.failedToDeleteFile(error.localizedDescription)
                }
            }

            if let thumbnailURL = asset.thumbnailURL(relativeTo: rootDirectory) {
                try? fileManager.removeItem(at: thumbnailURL)
            }

            return asset
        }
    }

    public func migrateLegacyLibraryLayout() throws -> MediaLibraryMigrationSummary {
        try withLock {
            try migrateLegacyLibraryLayoutLocked()
        }
    }

    public func reindexLibrary() throws -> MediaLibraryReindexSummary {
        try withLock {
            _ = try migrateLegacyLibraryLayoutLocked()
            return try reindexLibraryLocked()
        }
    }

    public func migrateLegacyLibraryAndReindex() throws -> MediaLibraryMaintenanceSummary {
        try withLock {
            let migration = try migrateLegacyLibraryLayoutLocked()
            let reindex = try reindexLibraryLocked()
            return MediaLibraryMaintenanceSummary(migration: migration, reindex: reindex)
        }
    }

    private func recentAssetsLocked(limit: Int, mediaType: MediaType?) throws -> [ImageAsset] {
        let sql: String
        if mediaType == nil {
            sql = """
            SELECT id, media_type, original_filename, stored_filename, relative_path, thumbnail_relative_path, byte_size, duration_seconds, imported_at, is_favorite
            FROM images
            ORDER BY imported_at DESC
            LIMIT ?;
            """
        } else {
            sql = """
            SELECT id, media_type, original_filename, stored_filename, relative_path, thumbnail_relative_path, byte_size, duration_seconds, imported_at, is_favorite
            FROM images
            WHERE media_type = ?
            ORDER BY imported_at DESC
            LIMIT ?;
            """
        }

        let statement = try Self.prepare(sql, in: database)
        defer { sqlite3_finalize(statement) }

        if let mediaType {
            sqlite3_bind_text(statement, 1, mediaType.rawValue, -1, sqliteTransient)
            sqlite3_bind_int(statement, 2, Int32(limit))
        } else {
            sqlite3_bind_int(statement, 1, Int32(limit))
        }

        var assets: [ImageAsset] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            assets.append(try Self.makeAsset(from: statement))
        }

        return assets
    }

    private func assetCountLocked() throws -> Int {
        let statement = try Self.prepare("SELECT COUNT(*) FROM images;", in: database)
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw ImageLibraryStoreError.failedToExecuteStatement(Self.lastErrorMessage(in: database))
        }

        return Int(sqlite3_column_int64(statement, 0))
    }

    private func assetCountLocked(in scope: ImageSelectionScope) throws -> Int {
        let sql = scope.favoritesOnly
            ? "SELECT COUNT(*) FROM images WHERE media_type = ? AND is_favorite = 1;"
            : "SELECT COUNT(*) FROM images WHERE media_type = ?;"

        let statement = try Self.prepare(sql, in: database)
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, scope.mediaType.rawValue, -1, sqliteTransient)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw ImageLibraryStoreError.failedToExecuteStatement(Self.lastErrorMessage(in: database))
        }

        return Int(sqlite3_column_int64(statement, 0))
    }

    private func libraryCountsLocked() throws -> LibraryCountSnapshot {
        let statement = try Self.prepare(
            """
            SELECT
                COUNT(*) AS asset_count,
                SUM(CASE WHEN media_type = 'photo' THEN 1 ELSE 0 END) AS photo_count,
                SUM(CASE WHEN media_type = 'video' THEN 1 ELSE 0 END) AS video_count,
                SUM(CASE WHEN media_type = 'photo' AND is_favorite = 1 THEN 1 ELSE 0 END) AS favorite_photo_count,
                SUM(CASE WHEN media_type = 'video' AND is_favorite = 1 THEN 1 ELSE 0 END) AS favorite_video_count
            FROM images;
            """,
            in: database
        )
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw ImageLibraryStoreError.failedToExecuteStatement(Self.lastErrorMessage(in: database))
        }

        return LibraryCountSnapshot(
            assetCount: Int(sqlite3_column_int64(statement, 0)),
            photoCount: Int(sqlite3_column_int64(statement, 1)),
            videoCount: Int(sqlite3_column_int64(statement, 2)),
            favoritePhotoCount: Int(sqlite3_column_int64(statement, 3)),
            favoriteVideoCount: Int(sqlite3_column_int64(statement, 4))
        )
    }

    private func importAsset(from externalURL: URL, originalFilenameOverride: String?, mediaType: MediaType?) throws -> ImageAsset {
        let preferredFilename = originalFilenameOverride ?? externalURL.lastPathComponent
        let inferredMediaType = mediaType
            ?? MediaType.infer(fromPathExtension: URL(fileURLWithPath: preferredFilename).pathExtension)
            ?? MediaType.infer(from: externalURL)
        guard let mediaType = inferredMediaType else {
            throw ImageLibraryStoreError.unsupportedMediaFile(preferredFilename)
        }

        let assetID = UUID()
        let filenameExtensionFromPreferredName = URL(fileURLWithPath: preferredFilename).pathExtension
        let filenameExtension = filenameExtensionFromPreferredName.isEmpty
            ? externalURL.pathExtension
            : filenameExtensionFromPreferredName
        let normalizedExtension = filenameExtension.lowercased()
        let storedFilename = normalizedExtension.isEmpty
            ? assetID.uuidString
            : "\(assetID.uuidString).\(normalizedExtension)"

        let destinationURL = directory(for: mediaType).appending(path: storedFilename)
        do {
            try fileManager.createDirectory(at: directory(for: mediaType), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: externalURL, to: destinationURL)
        } catch {
            throw ImageLibraryStoreError.failedToCopyFile(error.localizedDescription)
        }

        let byteSize = try byteSize(at: destinationURL)
        let durationSeconds = mediaType == .video ? videoDurationSeconds(at: destinationURL) : nil
        let asset = ImageAsset(
            id: assetID,
            mediaType: mediaType,
            originalFilename: preferredFilename,
            storedFilename: storedFilename,
            relativePath: relativePath(for: storedFilename, mediaType: mediaType),
            byteSize: byteSize,
            durationSeconds: durationSeconds,
            isFavorite: false,
            importedAt: Date()
        )

        do {
            try insertAsset(asset)
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }

        return asset
    }

    private func insertAsset(_ asset: ImageAsset) throws {
        let statement = try Self.prepare(
            """
            INSERT INTO images (
                id,
                media_type,
                original_filename,
                stored_filename,
                relative_path,
                thumbnail_relative_path,
                byte_size,
                duration_seconds,
                imported_at,
                is_favorite
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            in: database
        )
        defer { sqlite3_finalize(statement) }
        try bind(asset: asset, toInsertStatement: statement)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ImageLibraryStoreError.failedToExecuteStatement(Self.lastErrorMessage(in: database))
        }
    }

    private func bind(asset: ImageAsset, toInsertStatement statement: OpaquePointer?) throws {
        sqlite3_bind_text(statement, 1, asset.id.uuidString, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, asset.mediaType.rawValue, -1, sqliteTransient)
        sqlite3_bind_text(statement, 3, asset.originalFilename, -1, sqliteTransient)
        sqlite3_bind_text(statement, 4, asset.storedFilename, -1, sqliteTransient)
        sqlite3_bind_text(statement, 5, asset.relativePath, -1, sqliteTransient)
        if let thumbnailRelativePath = asset.thumbnailRelativePath {
            sqlite3_bind_text(statement, 6, thumbnailRelativePath, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(statement, 6)
        }
        sqlite3_bind_int64(statement, 7, asset.byteSize)
        if let durationSeconds = asset.durationSeconds {
            sqlite3_bind_double(statement, 8, durationSeconds)
        } else {
            sqlite3_bind_null(statement, 8)
        }
        sqlite3_bind_double(statement, 9, asset.importedAt.timeIntervalSince1970)
        sqlite3_bind_int(statement, 10, asset.isFavorite ? 1 : 0)
    }

    private func migrateLegacyLibraryLayoutLocked() throws -> MediaLibraryMigrationSummary {
        var renamedLegacyDirectories: [String] = []
        var movedPhotoFileCount = 0
        var movedVideoFileCount = 0

        let legacyDirectories = legacyDirectoryURLs().filter { fileManager.fileExists(atPath: $0.path) }
        if legacyDirectories.isEmpty == false {
            let canRenameLegacyDirectory = try {
                if photosDirectoryExists() == false {
                    return true
                }

                return try directoryIsEmpty(photosDirectory) && fileManager.fileExists(atPath: photosDirectory.path)
            }()

            if canRenameLegacyDirectory, let renameCandidate = legacyDirectories.first {
                if fileManager.fileExists(atPath: photosDirectory.path), try directoryIsEmpty(photosDirectory) {
                    try fileManager.removeItem(at: photosDirectory)
                }

                do {
                    try fileManager.moveItem(at: renameCandidate, to: photosDirectory)
                    renamedLegacyDirectories.append(renameCandidate.lastPathComponent)
                } catch {
                    try fileManager.createDirectory(at: photosDirectory, withIntermediateDirectories: true)
                    let movedCounts = try moveLegacyFiles(from: renameCandidate)
                    movedPhotoFileCount += movedCounts.photoCount
                    movedVideoFileCount += movedCounts.videoCount
                }
            }
        }

        try fileManager.createDirectory(at: photosDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: videosDirectory, withIntermediateDirectories: true)

        for legacyDirectory in legacyDirectoryURLs() where fileManager.fileExists(atPath: legacyDirectory.path) {
            let movedCounts = try moveLegacyFiles(from: legacyDirectory)
            movedPhotoFileCount += movedCounts.photoCount
            movedVideoFileCount += movedCounts.videoCount
        }

        movedVideoFileCount += try moveVideoFilesOutOfPhotosLocked()

        return MediaLibraryMigrationSummary(
            renamedLegacyDirectories: renamedLegacyDirectories,
            movedPhotoFileCount: movedPhotoFileCount,
            movedVideoFileCount: movedVideoFileCount
        )
    }

    private func reindexLibraryLocked() throws -> MediaLibraryReindexSummary {
        _ = try migrateLegacyLibraryLayoutLocked()

        let existingLookup = try existingAssetLookup()
        let insertStatement = try Self.prepare(
            """
            INSERT INTO images (
                id,
                media_type,
                original_filename,
                stored_filename,
                relative_path,
                thumbnail_relative_path,
                byte_size,
                duration_seconds,
                imported_at,
                is_favorite
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            in: database
        )
        defer { sqlite3_finalize(insertStatement) }

        var indexedPhotoCount = 0
        var indexedVideoCount = 0
        var skippedFileCount = 0
        var reusedAssetIDs: Set<UUID> = []

        do {
            try Self.execute("BEGIN IMMEDIATE TRANSACTION;", in: database)
            try Self.execute("DELETE FROM images;", in: database)

            for mediaType in MediaType.allCases {
                let directory = directory(for: mediaType)
                guard fileManager.fileExists(atPath: directory.path) else { continue }

                let enumerator = fileManager.enumerator(
                    at: directory,
                    includingPropertiesForKeys: [
                        .creationDateKey,
                        .contentModificationDateKey,
                        .fileSizeKey,
                        .isRegularFileKey
                    ],
                    options: [.skipsHiddenFiles]
                )

                while let fileURL = enumerator?.nextObject() as? URL {
                    guard try isRegularFile(fileURL) else { continue }
                    guard MediaType.infer(from: fileURL) == mediaType else {
                        skippedFileCount += 1
                        continue
                    }

                    let relativePath = try relativePathString(for: fileURL, relativeTo: rootDirectory)
                    let storedFilename = fileURL.lastPathComponent
                    let existingSnapshot = existingSnapshot(
                        for: relativePath,
                        storedFilename: storedFilename,
                        mediaType: mediaType,
                        from: existingLookup,
                        excluding: reusedAssetIDs
                    )

                    let asset = ImageAsset(
                        id: existingSnapshot?.id ?? UUID(),
                        mediaType: mediaType,
                        originalFilename: existingSnapshot?.originalFilename ?? storedFilename,
                        storedFilename: storedFilename,
                        relativePath: relativePath,
                        thumbnailRelativePath: existingSnapshot?.thumbnailRelativePath,
                        byteSize: try byteSize(at: fileURL),
                        durationSeconds: mediaType == .video
                            ? (existingSnapshot?.durationSeconds ?? videoDurationSeconds(at: fileURL))
                            : nil,
                        isFavorite: existingSnapshot?.isFavorite ?? false,
                        importedAt: existingSnapshot?.importedAt ?? fileDate(for: fileURL)
                    )

                    sqlite3_clear_bindings(insertStatement)
                    sqlite3_reset(insertStatement)
                    try bind(asset: asset, toInsertStatement: insertStatement)

                    guard sqlite3_step(insertStatement) == SQLITE_DONE else {
                        throw ImageLibraryStoreError.failedToExecuteStatement(Self.lastErrorMessage(in: database))
                    }

                    if let existingSnapshot {
                        reusedAssetIDs.insert(existingSnapshot.id)
                    }

                    switch mediaType {
                    case .photo:
                        indexedPhotoCount += 1
                    case .video:
                        indexedVideoCount += 1
                    }
                }
            }

            try Self.execute("COMMIT;", in: database)
        } catch {
            try? Self.execute("ROLLBACK;", in: database)
            throw error
        }

        try? Self.execute("PRAGMA optimize;", in: database)

        return MediaLibraryReindexSummary(
            indexedAssetCount: indexedPhotoCount + indexedVideoCount,
            indexedPhotoCount: indexedPhotoCount,
            indexedVideoCount: indexedVideoCount,
            skippedFileCount: skippedFileCount
        )
    }

    private func existingAssetLookup() throws -> IndexedAssetLookup {
        let statement = try Self.prepare(
            """
            SELECT id, media_type, original_filename, stored_filename, relative_path, thumbnail_relative_path, byte_size, duration_seconds, imported_at, is_favorite
            FROM images;
            """,
            in: database
        )
        defer { sqlite3_finalize(statement) }

        var byRelativePath: [String: IndexedAssetSnapshot] = [:]
        var byStoredFilename: [String: [IndexedAssetSnapshot]] = [:]

        while sqlite3_step(statement) == SQLITE_ROW {
            let asset = try Self.makeAsset(from: statement)
            let snapshot = IndexedAssetSnapshot(
                id: asset.id,
                originalFilename: asset.originalFilename,
                storedFilename: asset.storedFilename,
                relativePath: asset.relativePath,
                thumbnailRelativePath: asset.thumbnailRelativePath,
                byteSize: asset.byteSize,
                durationSeconds: asset.durationSeconds,
                mediaType: asset.mediaType,
                isFavorite: asset.isFavorite,
                importedAt: asset.importedAt
            )

            byRelativePath[snapshot.relativePath] = snapshot
            byStoredFilename[snapshot.storedFilename, default: []].append(snapshot)
        }

        return IndexedAssetLookup(byRelativePath: byRelativePath, byStoredFilename: byStoredFilename)
    }

    private func backfillMissingVideoDurationsLocked() throws {
        let statement = try Self.prepare(
            """
            SELECT id, media_type, original_filename, stored_filename, relative_path, thumbnail_relative_path, byte_size, duration_seconds, imported_at, is_favorite
            FROM images
            WHERE media_type = 'video' AND duration_seconds IS NULL;
            """,
            in: database
        )
        defer { sqlite3_finalize(statement) }

        var missingDurationAssets: [ImageAsset] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            missingDurationAssets.append(try Self.makeAsset(from: statement))
        }

        for asset in missingDurationAssets {
            guard let durationSeconds = videoDurationSeconds(at: asset.fileURL(relativeTo: rootDirectory)) else {
                continue
            }
            try updateVideoDurationLocked(assetID: asset.id, durationSeconds: durationSeconds)
        }
    }

    private func updateVideoDurationLocked(assetID: UUID, durationSeconds: Double) throws {
        let statement = try Self.prepare(
            """
            UPDATE images
            SET duration_seconds = ?
            WHERE id = ? AND media_type = 'video';
            """,
            in: database
        )
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_double(statement, 1, durationSeconds)
        sqlite3_bind_text(statement, 2, assetID.uuidString, -1, sqliteTransient)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ImageLibraryStoreError.failedToExecuteStatement(Self.lastErrorMessage(in: database))
        }
    }

    private func existingSnapshot(
        for relativePath: String,
        storedFilename: String,
        mediaType: MediaType,
        from lookup: IndexedAssetLookup,
        excluding usedAssetIDs: Set<UUID>
    ) -> IndexedAssetSnapshot? {
        if let exactMatch = lookup.byRelativePath[relativePath],
           exactMatch.mediaType == mediaType,
           usedAssetIDs.contains(exactMatch.id) == false {
            return exactMatch
        }

        return lookup.byStoredFilename[storedFilename]?.first { snapshot in
            snapshot.mediaType == mediaType && usedAssetIDs.contains(snapshot.id) == false
        }
    }

    private func legacyDirectoryURLs() -> [URL] {
        [
            rootDirectory.appending(path: "data", directoryHint: .isDirectory),
            rootDirectory.appending(path: "Data", directoryHint: .isDirectory),
            rootDirectory.appending(path: "Images", directoryHint: .isDirectory)
        ]
        .filter { $0.standardizedFileURL != photosDirectory.standardizedFileURL }
        .filter { $0.standardizedFileURL != videosDirectory.standardizedFileURL }
    }

    private func moveLegacyFiles(from legacyDirectory: URL) throws -> (photoCount: Int, videoCount: Int) {
        guard fileManager.fileExists(atPath: legacyDirectory.path) else {
            return (0, 0)
        }

        var movedPhotoCount = 0
        var movedVideoCount = 0
        let enumerator = fileManager.enumerator(
            at: legacyDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        while let fileURL = enumerator?.nextObject() as? URL {
            guard try isRegularFile(fileURL) else { continue }

            let mediaType = MediaType.infer(from: fileURL) ?? .photo
            let destinationRoot = directory(for: mediaType)
            let destinationURL = try destinationURLForMovedFile(
                at: fileURL,
                from: legacyDirectory,
                to: destinationRoot
            )
            try moveFile(at: fileURL, to: destinationURL)

            switch mediaType {
            case .photo:
                movedPhotoCount += 1
            case .video:
                movedVideoCount += 1
            }
        }

        try? fileManager.removeItem(at: legacyDirectory)
        return (movedPhotoCount, movedVideoCount)
    }

    private func moveVideoFilesOutOfPhotosLocked() throws -> Int {
        guard fileManager.fileExists(atPath: photosDirectory.path) else {
            return 0
        }

        var movedVideoCount = 0
        let enumerator = fileManager.enumerator(
            at: photosDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        while let fileURL = enumerator?.nextObject() as? URL {
            guard try isRegularFile(fileURL) else { continue }
            guard MediaType.infer(from: fileURL) == .video else { continue }

            let destinationURL = try destinationURLForMovedFile(
                at: fileURL,
                from: photosDirectory,
                to: videosDirectory
            )
            try moveFile(at: fileURL, to: destinationURL)
            movedVideoCount += 1
        }

        return movedVideoCount
    }

    private func destinationURLForMovedFile(at fileURL: URL, from sourceRoot: URL, to destinationRoot: URL) throws -> URL {
        let relativePath = try relativePathString(for: fileURL, relativeTo: sourceRoot)
        let relativeDirectoryPath = URL(fileURLWithPath: relativePath).deletingLastPathComponent().path
        let targetDirectory = relativeDirectoryPath == "/"
            ? destinationRoot
            : destinationRoot.appending(path: relativeDirectoryPath, directoryHint: .isDirectory)

        try fileManager.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        return uniqueDestinationURL(for: fileURL.lastPathComponent, in: targetDirectory)
    }

    private func uniqueDestinationURL(for preferredFilename: String, in directory: URL) -> URL {
        let baseName = URL(fileURLWithPath: preferredFilename).deletingPathExtension().lastPathComponent
        let pathExtension = URL(fileURLWithPath: preferredFilename).pathExtension
        var candidateURL = directory.appending(path: preferredFilename)

        while fileManager.fileExists(atPath: candidateURL.path) {
            let uniquedFilename = pathExtension.isEmpty
                ? "\(baseName)-\(UUID().uuidString)"
                : "\(baseName)-\(UUID().uuidString).\(pathExtension)"
            candidateURL = directory.appending(path: uniquedFilename)
        }

        return candidateURL
    }

    private func moveFile(at sourceURL: URL, to destinationURL: URL) throws {
        do {
            try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        } catch {
            do {
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
                try fileManager.removeItem(at: sourceURL)
            } catch {
                throw ImageLibraryStoreError.failedToMoveFile(error.localizedDescription)
            }
        }
    }

    private func directory(for mediaType: MediaType) -> URL {
        switch mediaType {
        case .photo:
            photosDirectory
        case .video:
            videosDirectory
        }
    }

    private func relativePath(for storedFilename: String, mediaType: MediaType) -> String {
        "\(mediaType.directoryName)/\(storedFilename)"
    }

    private func byteSize(at fileURL: URL) throws -> Int64 {
        do {
            let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
            return (attributes[.size] as? NSNumber)?.int64Value ?? 0
        } catch {
            throw ImageLibraryStoreError.failedToReadAttributes(error.localizedDescription)
        }
    }

    private func videoDurationSeconds(at fileURL: URL) -> Double? {
        let seconds = AVURLAsset(url: fileURL).duration.seconds
        guard seconds.isFinite, seconds > 0 else {
            return nil
        }
        return seconds
    }

    private func makeVideoThumbnailImage(for asset: ImageAsset) throws -> CGImage? {
        let videoURL = asset.fileURL(relativeTo: rootDirectory)
        guard fileManager.fileExists(atPath: videoURL.path) else {
            return nil
        }

        let avAsset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: avAsset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 960)

        for time in [CMTime(seconds: 0.1, preferredTimescale: 600), .zero] {
            if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                return cgImage
            }
        }

        return nil
    }

    private func writeJPEGThumbnail(_ image: CGImage, to destinationURL: URL) throws {
        do {
            try fileManager.createDirectory(at: thumbnailsDirectory, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
        } catch {
            throw ImageLibraryStoreError.failedToCopyFile(error.localizedDescription)
        }

        guard let destination = CGImageDestinationCreateWithURL(
            destinationURL as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw ImageLibraryStoreError.failedToCopyFile("Could not create a thumbnail image destination.")
        }

        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.82
        ] as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw ImageLibraryStoreError.failedToCopyFile("Could not write the generated thumbnail.")
        }
    }

    private func fileDate(for fileURL: URL) -> Date {
        let resourceValues = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        return resourceValues?.contentModificationDate
            ?? resourceValues?.creationDate
            ?? Date()
    }

    private func photosDirectoryExists() -> Bool {
        fileManager.fileExists(atPath: photosDirectory.path)
    }

    private func directoryIsEmpty(_ directoryURL: URL) throws -> Bool {
        let contents = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return contents.isEmpty
    }

    private func isRegularFile(_ fileURL: URL) throws -> Bool {
        let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
        return resourceValues.isRegularFile == true
    }

    private func relativePathString(for fileURL: URL, relativeTo rootURL: URL) throws -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else {
            throw ImageLibraryStoreError.failedToReadAttributes("Could not calculate a relative path for \(fileURL.lastPathComponent).")
        }

        let relativePath = String(filePath.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard relativePath.isEmpty == false else {
            throw ImageLibraryStoreError.failedToReadAttributes("The relative path for \(fileURL.lastPathComponent) was empty.")
        }
        return relativePath
    }

    private static func openDatabase(at url: URL) throws -> OpaquePointer? {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK else {
            defer {
                if let database {
                    sqlite3_close(database)
                }
            }
            let message = lastErrorMessage(in: database)
            throw ImageLibraryStoreError.failedToOpenDatabase(message)
        }

        return database
    }

    private static func configureDatabase(_ database: OpaquePointer?) throws {
        try execute("PRAGMA journal_mode = WAL;", in: database)
        try execute("PRAGMA synchronous = NORMAL;", in: database)
        try execute("PRAGMA temp_store = MEMORY;", in: database)
    }

    private static func execute(_ sql: String, in database: OpaquePointer?) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorPointer)
        if result != SQLITE_OK {
            let message = errorPointer.map { String(cString: $0) } ?? lastErrorMessage(in: database)
            sqlite3_free(errorPointer)
            throw ImageLibraryStoreError.failedToExecuteStatement(message)
        }
    }

    private static func prepare(_ sql: String, in database: OpaquePointer?) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK else {
            throw ImageLibraryStoreError.failedToPrepareStatement(lastErrorMessage(in: database))
        }
        return statement
    }

    private static func ensureFavoriteColumn(in database: OpaquePointer?) throws {
        guard try tableHasColumn(named: "is_favorite", in: "images", database: database) == false else {
            return
        }

        try execute(
            """
            ALTER TABLE images
            ADD COLUMN is_favorite INTEGER NOT NULL DEFAULT 0;
            """,
            in: database
        )
    }

    private static func ensureMediaTypeColumn(in database: OpaquePointer?) throws {
        guard try tableHasColumn(named: "media_type", in: "images", database: database) == false else {
            return
        }

        try execute(
            """
            ALTER TABLE images
            ADD COLUMN media_type TEXT NOT NULL DEFAULT 'photo';
            """,
            in: database
        )
    }

    private static func ensureThumbnailRelativePathColumn(in database: OpaquePointer?) throws {
        guard try tableHasColumn(named: "thumbnail_relative_path", in: "images", database: database) == false else {
            return
        }

        try execute(
            """
            ALTER TABLE images
            ADD COLUMN thumbnail_relative_path TEXT;
            """,
            in: database
        )
    }

    private static func ensureDurationSecondsColumn(in database: OpaquePointer?) throws {
        guard try tableHasColumn(named: "duration_seconds", in: "images", database: database) == false else {
            return
        }

        try execute(
            """
            ALTER TABLE images
            ADD COLUMN duration_seconds REAL;
            """,
            in: database
        )
    }

    private static func tableHasColumn(named columnName: String, in tableName: String, database: OpaquePointer?) throws -> Bool {
        let statement = try prepare("PRAGMA table_info(\(tableName));", in: database)
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let namePointer = sqlite3_column_text(statement, 1) else {
                continue
            }

            if String(cString: namePointer) == columnName {
                return true
            }
        }

        return false
    }

    private func assetLocked(withID assetID: UUID) throws -> ImageAsset? {
        let statement = try Self.prepare(
            """
            SELECT id, media_type, original_filename, stored_filename, relative_path, thumbnail_relative_path, byte_size, duration_seconds, imported_at, is_favorite
            FROM images
            WHERE id = ?
            LIMIT 1;
            """,
            in: database
        )
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, assetID.uuidString, -1, sqliteTransient)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return try Self.makeAsset(from: statement)
    }

    private static func makeAsset(from statement: OpaquePointer?) throws -> ImageAsset {
        guard
            let idPointer = sqlite3_column_text(statement, 0),
            let mediaTypePointer = sqlite3_column_text(statement, 1),
            let originalFilenamePointer = sqlite3_column_text(statement, 2),
            let storedFilenamePointer = sqlite3_column_text(statement, 3),
            let relativePathPointer = sqlite3_column_text(statement, 4)
        else {
            throw ImageLibraryStoreError.failedToReadAttributes("Database row was missing one or more text values.")
        }

        let idString = String(cString: idPointer)
        guard let id = UUID(uuidString: idString) else {
            throw ImageLibraryStoreError.failedToReadAttributes("Stored asset ID was not a valid UUID.")
        }

        let mediaTypeString = String(cString: mediaTypePointer)
        let storedFilename = String(cString: storedFilenamePointer)
        let relativePath = String(cString: relativePathPointer)
        let thumbnailRelativePath = sqlite3_column_text(statement, 5).map { String(cString: $0) }
        let durationSeconds: Double? = sqlite3_column_type(statement, 7) == SQLITE_NULL
            ? nil
            : sqlite3_column_double(statement, 7)
        let inferredMediaType = MediaType(rawValue: mediaTypeString)
            ?? MediaType.infer(fromPathExtension: URL(fileURLWithPath: storedFilename).pathExtension)
            ?? MediaType.infer(fromPathExtension: URL(fileURLWithPath: relativePath).pathExtension)
            ?? .photo

        return ImageAsset(
            id: id,
            mediaType: inferredMediaType,
            originalFilename: String(cString: originalFilenamePointer),
            storedFilename: storedFilename,
            relativePath: relativePath,
            thumbnailRelativePath: thumbnailRelativePath,
            byteSize: sqlite3_column_int64(statement, 6),
            durationSeconds: durationSeconds,
            isFavorite: sqlite3_column_int(statement, 9) != 0,
            importedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8))
        )
    }

    private static func lastErrorMessage(in database: OpaquePointer?) -> String {
        guard let database, let message = sqlite3_errmsg(database) else {
            return "Unknown SQLite error."
        }
        return String(cString: message)
    }

    private func withLock<T>(_ operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
