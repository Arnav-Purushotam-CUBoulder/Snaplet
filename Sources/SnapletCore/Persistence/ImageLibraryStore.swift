import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum ImageLibraryStoreError: LocalizedError {
    case failedToOpenDatabase(String)
    case failedToPrepareStatement(String)
    case failedToExecuteStatement(String)
    case failedToCopyFile(String)
    case failedToReadAttributes(String)

    public var errorDescription: String? {
        switch self {
        case let .failedToOpenDatabase(message):
            "Failed to open SQLite database: \(message)"
        case let .failedToPrepareStatement(message):
            "Failed to prepare SQLite statement: \(message)"
        case let .failedToExecuteStatement(message):
            "Failed to execute SQLite statement: \(message)"
        case let .failedToCopyFile(message):
            "Failed to copy image into the local store: \(message)"
        case let .failedToReadAttributes(message):
            "Failed to read file attributes: \(message)"
        }
    }
}

public final class ImageLibraryStore: @unchecked Sendable {
    public let rootDirectory: URL
    public let imagesDirectory: URL
    public let databaseURL: URL

    private let fileManager: FileManager
    private let lock = NSRecursiveLock()
    private var database: OpaquePointer?

    public init(rootDirectory: URL, fileManager: FileManager = .default) throws {
        self.rootDirectory = rootDirectory
        self.imagesDirectory = rootDirectory.appending(path: "Images", directoryHint: .isDirectory)
        self.databaseURL = rootDirectory.appending(path: "snaplet.sqlite")
        self.fileManager = fileManager

        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)

        self.database = try Self.openDatabase(at: databaseURL)
        try Self.execute(
            """
            CREATE TABLE IF NOT EXISTS images (
                id TEXT PRIMARY KEY NOT NULL,
                original_filename TEXT NOT NULL,
                stored_filename TEXT NOT NULL,
                relative_path TEXT NOT NULL,
                byte_size INTEGER NOT NULL,
                imported_at REAL NOT NULL
            );
            """,
            in: database
        )
        try Self.ensureFavoriteColumn(in: database)
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
    }

    deinit {
        guard let database else { return }
        sqlite3_close(database)
    }

    public func importImages(from externalURLs: [URL]) throws -> [ImageAsset] {
        try withLock {
            try externalURLs.map(importImage)
        }
    }

    public func importReceivedFile(at localURL: URL, originalFilename: String) throws -> ImageAsset {
        try withLock {
            try importImage(from: localURL, originalFilenameOverride: originalFilename)
        }
    }

    public func randomAsset(favoritesOnly: Bool = false) throws -> ImageAsset? {
        try withLock {
            let sql: String
            if favoritesOnly {
                sql = """
                    SELECT id, original_filename, stored_filename, relative_path, byte_size, imported_at, is_favorite
                    FROM images
                    WHERE is_favorite = 1
                    ORDER BY RANDOM()
                    LIMIT 1;
                    """
            } else {
                sql = """
                    SELECT id, original_filename, stored_filename, relative_path, byte_size, imported_at, is_favorite
                    FROM images
                    ORDER BY RANDOM()
                    LIMIT 1;
                    """
            }

            let statement = try Self.prepare(
                sql,
                in: database
            )
            defer { sqlite3_finalize(statement) }

            guard sqlite3_step(statement) == SQLITE_ROW else {
                return nil
            }

            return try Self.makeAsset(from: statement)
        }
    }

    public func recentAssets(limit: Int = 30) throws -> [ImageAsset] {
        try withLock {
            let statement = try Self.prepare(
                """
                SELECT id, original_filename, stored_filename, relative_path, byte_size, imported_at, is_favorite
                FROM images
                ORDER BY imported_at DESC
                LIMIT ?;
                """,
                in: database
            )
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_int(statement, 1, Int32(limit))

            var assets: [ImageAsset] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                assets.append(try Self.makeAsset(from: statement))
            }

            return assets
        }
    }

    public func libraryStatus(limit: Int = 30) throws -> LibraryStatus {
        try withLock {
            LibraryStatus(
                imageCount: try assetCount(),
                recentAssets: try recentAssets(limit: limit)
            )
        }
    }

    public func assetCount() throws -> Int {
        try withLock {
            let statement = try Self.prepare(
                "SELECT COUNT(*) FROM images;",
                in: database
            )
            defer { sqlite3_finalize(statement) }

            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw ImageLibraryStoreError.failedToExecuteStatement(Self.lastErrorMessage(in: database))
            }

            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    public func updateFavoriteStatus(assetID: UUID, isFavorite: Bool) throws -> ImageAsset? {
        try withLock {
            guard try asset(withID: assetID) != nil else {
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

            return try asset(withID: assetID)
        }
    }

    private func importImage(from externalURL: URL) throws -> ImageAsset {
        try importImage(from: externalURL, originalFilenameOverride: nil)
    }

    private func importImage(from externalURL: URL, originalFilenameOverride: String?) throws -> ImageAsset {
        let assetID = UUID()
        let preferredFilename = originalFilenameOverride ?? externalURL.lastPathComponent
        let fileExtension = URL(fileURLWithPath: preferredFilename).pathExtension.isEmpty
            ? externalURL.pathExtension
            : URL(fileURLWithPath: preferredFilename).pathExtension
        let storedFilename: String
        if fileExtension.isEmpty {
            storedFilename = assetID.uuidString
        } else {
            storedFilename = "\(assetID.uuidString).\(fileExtension.lowercased())"
        }

        let destinationURL = imagesDirectory.appending(path: storedFilename)
        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: externalURL, to: destinationURL)
        } catch {
            throw ImageLibraryStoreError.failedToCopyFile(error.localizedDescription)
        }

        let byteSize: Int64
        do {
            let attributes = try fileManager.attributesOfItem(atPath: destinationURL.path)
            byteSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        } catch {
            throw ImageLibraryStoreError.failedToReadAttributes(error.localizedDescription)
        }

        let asset = ImageAsset(
            id: assetID,
            originalFilename: preferredFilename,
            storedFilename: storedFilename,
            relativePath: "Images/\(storedFilename)",
            byteSize: byteSize,
            isFavorite: false,
            importedAt: Date()
        )

        do {
            let statement = try Self.prepare(
                """
                INSERT INTO images (
                    id,
                    original_filename,
                    stored_filename,
                    relative_path,
                    byte_size,
                    is_favorite,
                    imported_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?);
                """,
                in: database
            )
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, asset.id.uuidString, -1, sqliteTransient)
            sqlite3_bind_text(statement, 2, asset.originalFilename, -1, sqliteTransient)
            sqlite3_bind_text(statement, 3, asset.storedFilename, -1, sqliteTransient)
            sqlite3_bind_text(statement, 4, asset.relativePath, -1, sqliteTransient)
            sqlite3_bind_int64(statement, 5, asset.byteSize)
            sqlite3_bind_int(statement, 6, asset.isFavorite ? 1 : 0)
            sqlite3_bind_double(statement, 7, asset.importedAt.timeIntervalSince1970)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw ImageLibraryStoreError.failedToExecuteStatement(Self.lastErrorMessage(in: database))
            }
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }

        return asset
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

    private func asset(withID assetID: UUID) throws -> ImageAsset? {
        let statement = try Self.prepare(
            """
            SELECT id, original_filename, stored_filename, relative_path, byte_size, imported_at, is_favorite
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
            let originalFilenamePointer = sqlite3_column_text(statement, 1),
            let storedFilenamePointer = sqlite3_column_text(statement, 2),
            let relativePathPointer = sqlite3_column_text(statement, 3)
        else {
            throw ImageLibraryStoreError.failedToReadAttributes("Database row was missing one or more text values.")
        }

        let idString = String(cString: idPointer)
        guard let id = UUID(uuidString: idString) else {
            throw ImageLibraryStoreError.failedToReadAttributes("Stored asset ID was not a valid UUID.")
        }

        return ImageAsset(
            id: id,
            originalFilename: String(cString: originalFilenamePointer),
            storedFilename: String(cString: storedFilenamePointer),
            relativePath: String(cString: relativePathPointer),
            byteSize: sqlite3_column_int64(statement, 4),
            isFavorite: sqlite3_column_int(statement, 6) != 0,
            importedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
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
