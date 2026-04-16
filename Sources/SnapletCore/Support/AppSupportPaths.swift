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
        let directory = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = directory
            .appending(path: appName, directoryHint: .isDirectory)
            .appending(path: "ViewerCache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
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
