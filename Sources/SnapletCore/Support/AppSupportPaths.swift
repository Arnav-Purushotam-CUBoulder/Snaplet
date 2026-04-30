import Foundation

public enum AppSupportPathsError: LocalizedError {
    case missingHostVolume(String)

    public var errorDescription: String? {
        switch self {
        case let .missingHostVolume(volumeName):
            "The host storage volume '\(volumeName)' is not mounted. Connect the drive and relaunch Snaplet Host."
        }
    }
}

public enum AppSupportPaths {
    public static let hostVolumeName = "Seagate Expansion Drive"

    public static func expectedHostRootDirectory(
        appName: String = "Snaplet",
        volumeName: String = hostVolumeName
    ) -> URL {
        URL(filePath: "/Volumes", directoryHint: .isDirectory)
            .appending(path: volumeName, directoryHint: .isDirectory)
            .appending(path: appName, directoryHint: .isDirectory)
            .appending(path: "HostData", directoryHint: .isDirectory)
    }

    public static func hostRootDirectory(
        appName: String = "Snaplet",
        volumeName: String = hostVolumeName
    ) throws -> URL {
        let volumeURL = try mountedHostVolumeURL(named: volumeName)
        let root = volumeURL
            .appending(path: appName, directoryHint: .isDirectory)
            .appending(path: "HostData", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    public static func viewerCacheDirectory(appName: String = "Snaplet") throws -> URL {
        let root = try persistentLocalDirectory(
            named: "ViewerCache",
            appName: appName,
            migrateFromLegacyCachesDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    public static func hostQueueCacheDirectory(appName: String = "Snaplet") throws -> URL {
        let root = try persistentLocalDirectory(
            named: "HostQueueCache",
            appName: appName,
            migrateFromLegacyCachesDirectory: false
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func persistentLocalDirectory(
        named directoryName: String,
        appName: String,
        migrateFromLegacyCachesDirectory: Bool
    ) throws -> URL {
        let applicationSupportDirectory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let appRoot = applicationSupportDirectory
            .appending(path: appName, directoryHint: .isDirectory)
        let destination = appRoot.appending(path: directoryName, directoryHint: .isDirectory)

        if migrateFromLegacyCachesDirectory {
            try migrateLegacyDirectoryIfNeeded(
                named: directoryName,
                appName: appName,
                destination: destination
            )
        }

        return destination
    }

    private static func migrateLegacyDirectoryIfNeeded(
        named directoryName: String,
        appName: String,
        destination: URL
    ) throws {
        let fileManager = FileManager.default
        let legacyCachesDirectory = try fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let legacyDirectory = legacyCachesDirectory
            .appending(path: appName, directoryHint: .isDirectory)
            .appending(path: directoryName, directoryHint: .isDirectory)

        guard fileManager.fileExists(atPath: legacyDirectory.path) else {
            return
        }

        let destinationExists = fileManager.fileExists(atPath: destination.path)
        if destinationExists {
            let destinationContents = try fileManager.contentsOfDirectory(
                at: destination,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            guard destinationContents.isEmpty else {
                return
            }
            try fileManager.removeItem(at: destination)
        } else {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }

        try fileManager.moveItem(at: legacyDirectory, to: destination)
    }

    private static func mountedHostVolumeURL(named volumeName: String) throws -> URL {
        let volumesDirectory = URL(filePath: "/Volumes", directoryHint: .isDirectory)
        let mountedVolumes = try FileManager.default.contentsOfDirectory(
            at: volumesDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        guard let volumeURL = mountedVolumes.first(where: { $0.lastPathComponent.hasPrefix(volumeName) }) else {
            throw AppSupportPathsError.missingHostVolume(volumeName)
        }

        return volumeURL
    }
}
