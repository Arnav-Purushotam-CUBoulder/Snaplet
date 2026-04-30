import Combine
import Foundation
@preconcurrency import MultipeerConnectivity
#if os(iOS)
import UIKit
#endif

public final class PeerHostService: NSObject, ObservableObject, @unchecked Sendable {
    private struct PreparedTransfer {
        let asset: ImageAsset
        let scope: ImageSelectionScope
        let resourceName: String
        let sendURL: URL
        let cleanupURL: URL?
    }

    private struct PersistedPreparedTransfer: Codable {
        let assetID: UUID
        let scope: ImageSelectionScope
        let resourceName: String
        let stagedFilename: String?
    }

    private struct PersistedPreparedTransferScope: Codable {
        let scope: ImageSelectionScope
        let transfers: [PersistedPreparedTransfer]
    }

    private struct PersistedPreparedTransferState: Codable {
        let version: Int
        let scopes: [PersistedPreparedTransferScope]
    }

    @Published public private(set) var isAdvertising = false
    @Published public private(set) var connectionStatus = "Idle"
    @Published public private(set) var connectedPeerNames: [String] = []
    @Published public private(set) var activityLog: [String] = []
    @Published public private(set) var lastError: String?
    @Published public private(set) var preparedPhotoQueueCount = 0
    @Published public private(set) var preparedPhotoQueueTargetCount = 0
    @Published public private(set) var preparedFavoritePhotoQueueCount = 0
    @Published public private(set) var preparedFavoritePhotoQueueTargetCount = 0

    private let imageLibraryStore: ImageLibraryStore
    private let peerID: MCPeerID
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let mediaStreamingServer: MediaStreamingServer
    private let transferStagingDirectory: URL
    private let preparedTransferStateURL: URL
    private let stateQueue = DispatchQueue(label: "snaplet.host.service.state")
    private let workQueue = DispatchQueue(label: "snaplet.host.service", qos: .userInitiated, attributes: .concurrent)
    private let persistenceQueue = DispatchQueue(label: "snaplet.host.service.persistence")
    private let preparedPhotoTransferTargetCount = 500
    private let preparedFavoritePhotoTransferTargetCount = 200
    private let defaultPreparedTransferTargetCount = 24
    private let maxConcurrentPreparedTransfers = 4
    private let preparedTransferMaintenanceInterval: TimeInterval = 5 * 60
    private var preparedTransfers: [ImageSelectionScope: [PreparedTransfer]] = [:]
    private var preparingTransferCount: [ImageSelectionScope: Int] = [:]
    private var preparedTransferGeneration: [ImageSelectionScope: Int] = [:]
    private var peerSessionStates: [String: MCSessionState] = [:]
    private var pendingVideoThumbnailUploads: [String: UUID] = [:]
    private var preparedTransferMaintenanceTimer: DispatchSourceTimer?
    private var preparedTransferPersistenceScheduled = false
    private var hasRestoredPreparedTransferState = false
    private var isStarted = false

    public var onLibraryMutated: (@Sendable () -> Void)?

    private struct InvitationReservation {
        let replacedPeerNames: [String]
    }

    public init(imageLibraryStore: ImageLibraryStore, displayName: String? = nil) {
        self.imageLibraryStore = imageLibraryStore
        self.peerID = MCPeerID(displayName: displayName ?? Self.defaultDisplayName())
        self.session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        self.advertiser = MCNearbyServiceAdvertiser(
            peer: peerID,
            discoveryInfo: nil,
            serviceType: SnapletPeerConfiguration.serviceType
        )
        self.mediaStreamingServer = MediaStreamingServer()
        let persistentCacheRoot = (try? AppSupportPaths.hostQueueCacheDirectory())
            ?? FileManager.default.temporaryDirectory.appending(path: "snaplet-host-queue-cache", directoryHint: .isDirectory)
        self.transferStagingDirectory = persistentCacheRoot
            .appending(path: "PreparedTransfers", directoryHint: .isDirectory)
        self.preparedTransferStateURL = persistentCacheRoot.appending(path: "prepared-transfer-state.json")

        super.init()

        try? FileManager.default.createDirectory(at: transferStagingDirectory, withIntermediateDirectories: true)
        session.delegate = self
        advertiser.delegate = self
    }

    public func start() {
        let shouldStart = stateQueue.sync { () -> Bool in
            guard !isStarted else { return false }
            isStarted = true
            return true
        }
        guard shouldStart else { return }

        restorePreparedTransferStateIfNeeded()
        mediaStreamingServer.start()
        advertiser.startAdvertisingPeer()
        startPreparedTransferMaintenanceTimer()
        ensurePreparedTransfers(for: .all)
        ensurePreparedTransfers(for: .favorites)
        publishPreparedPhotoQueueStates()
        updatePublishedState {
            $0.isAdvertising = true
            $0.connectionStatus = "Advertising as \($0.peerID.displayName)"
            $0.appendLog("Advertising for iPhone viewers.")
            $0.appendLog("Maintaining a 500-photo warm cache and a 200-favorite-photo warm cache on local storage.")
        }
    }

    public func stop() {
        stateQueue.sync {
            isStarted = false
        }
        stopPreparedTransferMaintenanceTimer()
        advertiser.stopAdvertisingPeer()
        session.disconnect()
        mediaStreamingServer.stop()
        persistPreparedTransferStateNow()
        publishPreparedPhotoQueueStates()
        updatePublishedState {
            $0.isAdvertising = false
            $0.connectedPeerNames = []
            $0.connectionStatus = "Stopped"
            $0.appendLog("Stopped advertising.")
        }
    }

    private func startPreparedTransferMaintenanceTimer() {
        stopPreparedTransferMaintenanceTimer()

        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(
            deadline: .now() + preparedTransferMaintenanceInterval,
            repeating: preparedTransferMaintenanceInterval
        )
        timer.setEventHandler { [weak self] in
            self?.maintainPreparedTransferCache()
        }

        stateQueue.sync {
            preparedTransferMaintenanceTimer = timer
        }
        timer.resume()
    }

    private func stopPreparedTransferMaintenanceTimer() {
        let timer = stateQueue.sync { () -> DispatchSourceTimer? in
            let timer = preparedTransferMaintenanceTimer
            preparedTransferMaintenanceTimer = nil
            return timer
        }

        timer?.setEventHandler {}
        timer?.cancel()
    }

    private func maintainPreparedTransferCache() {
        let shouldMaintain = stateQueue.sync {
            isStarted
        }
        guard shouldMaintain else { return }

        ensurePreparedTransfers(for: .all)
        ensurePreparedTransfers(for: .favorites)
        publishPreparedPhotoQueueStates()
    }

    private func handleRandomImageRequest(
        from peerID: MCPeerID,
        purpose: ImageRequestPurpose,
        scope: ImageSelectionScope
    ) {
        do {
            let preparedTransfer = try takePreparedTransfer(for: scope) ?? makeDirectTransfer(for: scope)

            guard let preparedTransfer else {
                let failureMessage: String
                switch (scope.mediaType, scope.favoritesOnly) {
                case (.photo, false):
                    failureMessage = "No photos have been indexed yet."
                case (.photo, true):
                    failureMessage = "No favorite photos are marked yet."
                case (.video, false):
                    failureMessage = "No videos have been indexed yet."
                case (.video, true):
                    failureMessage = "No favorite videos are marked yet."
                }
                try sendMessage(.failure(failureMessage), to: [peerID])
                updatePublishedState {
                    let scopeDescription = self.logDescription(for: scope)
                    $0.appendLog("Random image request from \(peerID.displayName) failed because the \(scopeDescription) is empty.")
                }
                return
            }

            let streamURL = preparedTransfer.asset.mediaType == .video
                ? mediaStreamingServer.registerVideo(
                    at: preparedTransfer.sendURL,
                    byteSize: preparedTransfer.asset.byteSize
                )
                : nil

            let descriptor = ResourceDescriptor(
                assetID: preparedTransfer.asset.id,
                mediaType: preparedTransfer.asset.mediaType,
                resourceName: preparedTransfer.resourceName,
                originalFilename: preparedTransfer.asset.originalFilename,
                byteSize: preparedTransfer.asset.byteSize,
                isFavorite: preparedTransfer.asset.isFavorite,
                streamURL: streamURL
            )

            try sendMessage(.transferReady(descriptor, purpose: purpose, scope: scope), to: [peerID])
            ensurePreparedTransfers(for: scope)

            if preparedTransfer.asset.mediaType == .video, streamURL != nil {
                updatePublishedState {
                    let scopeDescription = self.logDescription(for: scope)
                    $0.appendLog("Started \(scopeDescription) video stream \(preparedTransfer.asset.originalFilename) for \(peerID.displayName).")
                }
                return
            }

            session.sendResource(
                at: preparedTransfer.sendURL,
                withName: preparedTransfer.resourceName,
                toPeer: peerID
            ) { [weak self] error in
                guard let self else { return }
                if let cleanupURL = preparedTransfer.cleanupURL {
                    try? FileManager.default.removeItem(at: cleanupURL)
                }

                if let error {
                    self.updatePublishedState {
                        $0.lastError = error.localizedDescription
                        $0.appendLog("Resource transfer to \(peerID.displayName) failed: \(error.localizedDescription)")
                    }
                    try? self.sendMessage(.failure("Transfer failed: \(error.localizedDescription)"), to: [peerID])
                } else {
                    self.updatePublishedState {
                        let scopeDescription = self.logDescription(for: scope)
                        $0.appendLog("Sent \(scopeDescription) \(preparedTransfer.asset.mediaType.singularDisplayName) \(preparedTransfer.asset.originalFilename) to \(peerID.displayName).")
                    }
                }
            }
        } catch {
            updatePublishedState {
                $0.lastError = error.localizedDescription
                $0.appendLog("Random image request failed: \(error.localizedDescription)")
            }
            try? sendMessage(.failure(error.localizedDescription), to: [peerID])
        }
    }

    private func handleSpecificAssetRequest(
        assetID: UUID,
        from peerID: MCPeerID,
        purpose: ImageRequestPurpose,
        scope: ImageSelectionScope
    ) {
        do {
            guard let asset = try imageLibraryStore.asset(withID: assetID), self.asset(asset, matches: scope) else {
                try sendMessage(.failure("That video is no longer available on the Mac host."), to: [peerID])
                updatePublishedState {
                    $0.appendLog("Specific asset request from \(peerID.displayName) failed because \(assetID.uuidString) was missing.")
                }
                return
            }

            let sendURL = asset.fileURL(relativeTo: imageLibraryStore.rootDirectory)
            let resourceName = "\(UUID().uuidString)-\(asset.storedFilename)"
            let streamURL = asset.mediaType == .video
                ? mediaStreamingServer.registerVideo(at: sendURL, byteSize: asset.byteSize)
                : nil

            let descriptor = ResourceDescriptor(
                assetID: asset.id,
                mediaType: asset.mediaType,
                resourceName: resourceName,
                originalFilename: asset.originalFilename,
                byteSize: asset.byteSize,
                isFavorite: asset.isFavorite,
                streamURL: streamURL
            )

            try sendMessage(.transferReady(descriptor, purpose: purpose, scope: scope), to: [peerID])

            if asset.mediaType == .video, streamURL != nil {
                updatePublishedState {
                    $0.appendLog("Started catalog video stream \(asset.originalFilename) for \(peerID.displayName).")
                }
                return
            }

            session.sendResource(at: sendURL, withName: resourceName, toPeer: peerID) { [weak self] error in
                guard let self else { return }

                if let error {
                    self.updatePublishedState {
                        $0.lastError = error.localizedDescription
                        $0.appendLog("Catalog resource transfer to \(peerID.displayName) failed: \(error.localizedDescription)")
                    }
                    try? self.sendMessage(.failure("Transfer failed: \(error.localizedDescription)"), to: [peerID])
                    return
                }

                self.updatePublishedState {
                    $0.appendLog("Sent catalog \(asset.mediaType.singularDisplayName) \(asset.originalFilename) to \(peerID.displayName).")
                }
            }
        } catch {
            updatePublishedState {
                $0.lastError = error.localizedDescription
                $0.appendLog("Specific asset request failed: \(error.localizedDescription)")
            }
            try? sendMessage(.failure(error.localizedDescription), to: [peerID])
        }
    }

    private func handleVideoCatalogRequest(
        from peerID: MCPeerID,
        scope: ImageSelectionScope,
        sort: VideoCatalogSort
    ) {
        do {
            let catalogScope: ImageSelectionScope = scope.favoritesOnly ? .favoriteVideos : .videos
            let assets = try imageLibraryStore.videoCatalogAssets(in: catalogScope, sort: sort)
            let items = assets.map { asset -> VideoCatalogItem in
                let thumbnailURL: URL?
                if let localThumbnailURL = try? imageLibraryStore.thumbnailURL(forVideoAsset: asset) {
                    thumbnailURL = mediaStreamingServer.registerResource(
                        at: localThumbnailURL,
                        byteSize: resourceByteSize(at: localThumbnailURL)
                    )
                } else {
                    thumbnailURL = nil
                }

                return VideoCatalogItem(
                    assetID: asset.id,
                    originalFilename: asset.originalFilename,
                    byteSize: asset.byteSize,
                    durationSeconds: asset.durationSeconds,
                    isFavorite: asset.isFavorite,
                    importedAt: asset.importedAt,
                    thumbnailURL: thumbnailURL
                )
            }

            try sendMessage(.videoCatalog(items: items, scope: catalogScope, sort: sort), to: [peerID])
            updatePublishedState {
                $0.appendLog("Sent \(items.count) \(catalogScope.favoritesOnly ? "favorite " : "")video catalog item\(items.count == 1 ? "" : "s") to \(peerID.displayName).")
            }
        } catch {
            updatePublishedState {
                $0.lastError = error.localizedDescription
                $0.appendLog("Video catalog request failed: \(error.localizedDescription)")
            }
            try? sendMessage(.failure("Video catalog failed: \(error.localizedDescription)"), to: [peerID])
        }
    }

    private func handleSetVideoThumbnail(assetID: UUID, resourceName: String, from peerID: MCPeerID) {
        stateQueue.sync {
            pendingVideoThumbnailUploads[resourceName] = assetID
        }
        updatePublishedState {
            $0.appendLog("Waiting for thumbnail upload \(resourceName) from \(peerID.displayName).")
        }
    }

    private func sendMessage(_ message: PeerMessage, to peers: [MCPeerID]) throws {
        let data = try message.encoded()
        try session.send(data, toPeers: peers, with: .reliable)
    }

    private func sendLibraryStatus(to peers: [MCPeerID]) throws {
        try sendMessage(.libraryStatus(summary: try imageLibraryStore.libraryStatus(limit: 0).summary), to: peers)
    }

    private func handleIncomingUpload(
        named resourceName: String,
        from peerID: MCPeerID,
        localURL: URL?,
        error: Error?
    ) {
        let peerName = peerID.displayName
        let pendingThumbnailAssetID = stateQueue.sync {
            pendingVideoThumbnailUploads.removeValue(forKey: resourceName)
        } ?? Self.thumbnailAssetID(from: resourceName)

        if let error {
            updatePublishedState {
                $0.lastError = error.localizedDescription
                $0.appendLog("Upload from \(peerName) failed: \(error.localizedDescription)")
            }
            try? sendMessage(.failure("Upload failed: \(error.localizedDescription)"), to: [peerID])
            return
        }

        guard let localURL else {
            updatePublishedState {
                $0.lastError = "Upload from \(peerName) finished without a file URL."
                $0.appendLog("Upload from \(peerName) finished without a file URL.")
            }
            try? sendMessage(.failure("Upload failed because the host did not receive a temporary file URL."), to: [peerID])
            return
        }

        if let pendingThumbnailAssetID {
            handleIncomingVideoThumbnailUpload(
                assetID: pendingThumbnailAssetID,
                resourceName: resourceName,
                from: peerID,
                localURL: localURL
            )
            return
        }

        do {
            let importedAsset = try imageLibraryStore.importReceivedFile(at: localURL, originalFilename: resourceName)
            let libraryStatus = try imageLibraryStore.libraryStatus(limit: 0)
            let descriptor = ResourceDescriptor(
                assetID: importedAsset.id,
                mediaType: importedAsset.mediaType,
                resourceName: importedAsset.storedFilename,
                originalFilename: importedAsset.originalFilename,
                byteSize: importedAsset.byteSize,
                isFavorite: importedAsset.isFavorite,
                streamURL: nil
            )

            try sendMessage(.uploadComplete(descriptor, count: libraryStatus.assetCount), to: [peerID])
            try sendLibraryStatus(to: session.connectedPeers)
            let primaryScope: ImageSelectionScope = importedAsset.mediaType == .photo ? .all : .videos
            let favoriteScope: ImageSelectionScope = importedAsset.mediaType == .photo ? .favorites : .favoriteVideos
            ensurePreparedTransfers(for: primaryScope)
            if importedAsset.isFavorite {
                ensurePreparedTransfers(for: favoriteScope)
            }

            updatePublishedState {
                $0.appendLog("Imported \(resourceName) from \(peerName).")
            }
            onLibraryMutated?()
        } catch {
            updatePublishedState {
                $0.lastError = error.localizedDescription
                $0.appendLog("Failed to index upload \(resourceName): \(error.localizedDescription)")
            }
            try? sendMessage(.failure("The Mac received \(resourceName) but could not import it: \(error.localizedDescription)"), to: [peerID])
        }
    }

    private func handleIncomingVideoThumbnailUpload(
        assetID: UUID,
        resourceName: String,
        from peerID: MCPeerID,
        localURL: URL
    ) {
        do {
            let updatedAsset = try imageLibraryStore.setVideoThumbnail(
                assetID: assetID,
                sourceURL: localURL,
                originalFilename: resourceName
            )
            try sendMessage(.videoThumbnailUpdated(assetID: updatedAsset.id), to: session.connectedPeers.isEmpty ? [peerID] : session.connectedPeers)

            updatePublishedState {
                $0.appendLog("Updated thumbnail for \(updatedAsset.originalFilename) from \(peerID.displayName).")
            }
            onLibraryMutated?()
        } catch {
            updatePublishedState {
                $0.lastError = error.localizedDescription
                $0.appendLog("Failed to update video thumbnail \(resourceName): \(error.localizedDescription)")
            }
            try? sendMessage(.failure("Thumbnail update failed: \(error.localizedDescription)"), to: [peerID])
        }
    }

    private func handleFavoriteUpdate(assetID: UUID, isFavorite: Bool, from peerID: MCPeerID) {
        do {
            guard let updatedAsset = try imageLibraryStore.updateFavoriteStatus(assetID: assetID, isFavorite: isFavorite) else {
                try sendMessage(.failure("That image is no longer indexed on the Mac host."), to: [peerID])
                updatePublishedState {
                    $0.appendLog("Favorite update from \(peerID.displayName) failed because the asset was missing.")
                }
                return
            }

            try sendMessage(.favoriteStatusUpdated(assetID: updatedAsset.id, isFavorite: updatedAsset.isFavorite), to: [peerID])
            try sendLibraryStatus(to: session.connectedPeers)
            let primaryScope: ImageSelectionScope = updatedAsset.mediaType == .photo ? .all : .videos
            let favoriteScope: ImageSelectionScope = updatedAsset.mediaType == .photo ? .favorites : .favoriteVideos
            removePreparedTransfers(matching: updatedAsset.id, from: favoriteScope)
            ensurePreparedTransfers(for: primaryScope)
            ensurePreparedTransfers(for: favoriteScope)
            updatePublishedState {
                let favoriteState = updatedAsset.isFavorite ? "favorite" : "not favorite"
                $0.appendLog("Marked \(updatedAsset.originalFilename) as \(favoriteState) for \(peerID.displayName).")
            }
            onLibraryMutated?()
        } catch {
            updatePublishedState {
                $0.lastError = error.localizedDescription
                $0.appendLog("Favorite update failed: \(error.localizedDescription)")
            }
            try? sendMessage(.failure("Favorite update failed: \(error.localizedDescription)"), to: [peerID])
        }
    }

    private func handleDeleteRequest(assetID: UUID, from peerID: MCPeerID) {
        do {
            guard let deletedAsset = try imageLibraryStore.deleteAsset(assetID: assetID) else {
                try sendMessage(.failure("That image is no longer indexed on the Mac host."), to: [peerID])
                updatePublishedState {
                    $0.appendLog("Delete request from \(peerID.displayName) failed because the asset was missing.")
                }
                return
            }

            let libraryStatus = try imageLibraryStore.libraryStatus(limit: 0)
            try sendMessage(.assetDeleted(assetID: deletedAsset.id, count: libraryStatus.assetCount), to: session.connectedPeers)
            try sendLibraryStatus(to: session.connectedPeers)
            let primaryScope: ImageSelectionScope = deletedAsset.mediaType == .photo ? .all : .videos
            let favoriteScope: ImageSelectionScope = deletedAsset.mediaType == .photo ? .favorites : .favoriteVideos
            removePreparedTransfers(matching: deletedAsset.id, from: primaryScope)
            removePreparedTransfers(matching: deletedAsset.id, from: favoriteScope)
            ensurePreparedTransfers(for: primaryScope)
            ensurePreparedTransfers(for: favoriteScope)

            updatePublishedState {
                $0.appendLog("Deleted \(deletedAsset.originalFilename) for \(peerID.displayName).")
            }
            onLibraryMutated?()
        } catch {
            updatePublishedState {
                $0.lastError = error.localizedDescription
                $0.appendLog("Delete request failed: \(error.localizedDescription)")
            }
            try? sendMessage(.failure("Delete failed: \(error.localizedDescription)"), to: [peerID])
        }
    }

    private func updatePublishedState(_ update: @Sendable @escaping (PeerHostService) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            update(self)
        }
    }

    private func reserveInvitationSlot(for peerID: MCPeerID) -> InvitationReservation {
        stateQueue.sync {
            let connectedPeerNames = Set(session.connectedPeers.map(\.displayName))
            peerSessionStates = peerSessionStates.filter { peerName, state in
                state == .connecting || connectedPeerNames.contains(peerName)
            }

            let replacedPeerNames = session.connectedPeers
                .filter { $0.displayName != peerID.displayName }
                .map(\.displayName)

            peerSessionStates[peerID.displayName] = .connecting
            return InvitationReservation(replacedPeerNames: replacedPeerNames)
        }
    }

    private func updatePeerSessionState(_ state: MCSessionState, for peerID: MCPeerID) {
        stateQueue.sync {
            if state == .notConnected {
                peerSessionStates.removeValue(forKey: peerID.displayName)
            } else {
                peerSessionStates[peerID.displayName] = state
            }
        }
    }

    private func takePreparedTransfer(for scope: ImageSelectionScope) throws -> PreparedTransfer? {
        while true {
            let preparedTransfer = stateQueue.sync { () -> PreparedTransfer? in
                guard let firstPreparedTransfer = preparedTransfers[scope]?.first else {
                    return nil
                }
                preparedTransfers[scope]?.removeFirst()
                return firstPreparedTransfer
            }
            if preparedTransfer != nil {
                schedulePreparedTransferStatePersistence()
            }

            if scope.isPhotoScope {
                publishPreparedPhotoQueueStates()
            }

            guard let preparedTransfer else {
                return nil
            }

            if let refreshedTransfer = try refreshedPreparedTransferIfEligible(preparedTransfer) {
                return refreshedTransfer
            }

            if let cleanupURL = preparedTransfer.cleanupURL {
                try? FileManager.default.removeItem(at: cleanupURL)
            }
            ensurePreparedTransfers(for: scope)
        }
    }

    private func prepareTransfer(for scope: ImageSelectionScope) throws -> PreparedTransfer? {
        guard let asset = try imageLibraryStore.randomAsset(in: scope) else {
            return nil
        }

        let sourceURL = asset.fileURL(relativeTo: imageLibraryStore.rootDirectory)
        let stagedPhotoURL: URL?
        if asset.mediaType == .photo, shouldStagePreparedPhotoTransfer(at: sourceURL) {
            stagedPhotoURL = try? stagePreparedPhotoTransfer(at: sourceURL, storedFilename: asset.storedFilename)
        } else {
            stagedPhotoURL = nil
        }

        return PreparedTransfer(
            asset: asset,
            scope: scope,
            resourceName: "\(UUID().uuidString)-\(asset.storedFilename)",
            sendURL: stagedPhotoURL ?? sourceURL,
            cleanupURL: stagedPhotoURL
        )
    }

    private func makeDirectTransfer(for scope: ImageSelectionScope) throws -> PreparedTransfer? {
        guard let asset = try imageLibraryStore.randomAsset(in: scope) else {
            return nil
        }

        return PreparedTransfer(
            asset: asset,
            scope: scope,
            resourceName: "\(UUID().uuidString)-\(asset.storedFilename)",
            sendURL: asset.fileURL(relativeTo: imageLibraryStore.rootDirectory),
            cleanupURL: nil
        )
    }

    private func shouldStagePreparedPhotoTransfer(at sourceURL: URL) -> Bool {
        sourceURL.path.hasPrefix("/Volumes/")
    }

    private func stagePreparedPhotoTransfer(at sourceURL: URL, storedFilename: String) throws -> URL {
        let stagedURL = transferStagingDirectory.appending(path: "\(UUID().uuidString)-\(storedFilename)")
        if FileManager.default.fileExists(atPath: stagedURL.path) {
            try FileManager.default.removeItem(at: stagedURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: stagedURL)
        return stagedURL
    }

    private func asset(_ asset: ImageAsset, matches scope: ImageSelectionScope) -> Bool {
        guard asset.mediaType == scope.mediaType else {
            return false
        }

        if scope.favoritesOnly {
            return asset.isFavorite
        }

        return true
    }

    private func refreshedPreparedTransferIfEligible(_ preparedTransfer: PreparedTransfer) throws -> PreparedTransfer? {
        guard let latestAsset = try imageLibraryStore.asset(withID: preparedTransfer.asset.id) else {
            return nil
        }
        guard asset(latestAsset, matches: preparedTransfer.scope) else {
            return nil
        }

        return PreparedTransfer(
            asset: latestAsset,
            scope: preparedTransfer.scope,
            resourceName: preparedTransfer.resourceName,
            sendURL: preparedTransfer.sendURL,
            cleanupURL: preparedTransfer.cleanupURL
        )
    }

    private func ensurePreparedTransfers(for scope: ImageSelectionScope) {
        let reservation = stateQueue.sync { () -> (generation: Int, taskCount: Int) in
            guard isStarted else {
                return (preparedTransferGeneration[scope, default: 0], 0)
            }

            let generation = preparedTransferGeneration[scope, default: 0]
            let readyCount = preparedTransfers[scope, default: []].count
            let preparingCount = preparingTransferCount[scope, default: 0]
            let targetCount = effectivePreparedTransferTargetCountLocked(for: scope)
            guard targetCount > 0 else {
                return (generation, 0)
            }
            let missingCount = max(targetCount - (readyCount + preparingCount), 0)
            let availableConcurrency = max(maxConcurrentPreparedTransfers - preparingCount, 0)
            let taskCount = min(missingCount, availableConcurrency)
            if taskCount > 0 {
                preparingTransferCount[scope, default: 0] = preparingCount + taskCount
            }
            return (generation, taskCount)
        }

        guard reservation.taskCount > 0 else { return }

        for _ in 0..<reservation.taskCount {
            workQueue.async { [weak self] in
                self?.prepareTransferAsync(for: scope, generation: reservation.generation)
            }
        }
    }

    private func prepareTransferAsync(for scope: ImageSelectionScope, generation: Int) {
        let preparedTransfer: PreparedTransfer?

        do {
            preparedTransfer = try prepareTransfer(for: scope)
        } catch {
            updatePublishedState {
                $0.lastError = error.localizedDescription
                $0.appendLog("Failed to warm a \(scope.rawValue) image transfer: \(error.localizedDescription)")
            }
            preparedTransfer = nil
        }

        let queueReadyTransfer: PreparedTransfer?
        var discardedURLs: [URL] = []

        do {
            if let preparedTransfer {
                queueReadyTransfer = try refreshedPreparedTransferIfEligible(preparedTransfer)
                if queueReadyTransfer == nil, let cleanupURL = preparedTransfer.cleanupURL {
                    discardedURLs.append(cleanupURL)
                }
            } else {
                queueReadyTransfer = nil
            }
        } catch {
            if let cleanupURL = preparedTransfer?.cleanupURL {
                discardedURLs.append(cleanupURL)
            }
            updatePublishedState {
                $0.lastError = error.localizedDescription
                $0.appendLog("Failed to validate a warmed \(scope.rawValue) transfer: \(error.localizedDescription)")
            }
            queueReadyTransfer = nil
        }

        let staleURLs: [URL] = stateQueue.sync {
            preparingTransferCount[scope] = max(0, preparingTransferCount[scope, default: 0] - 1)

            guard let queueReadyTransfer else {
                return discardedURLs
            }
            guard preparedTransferGeneration[scope, default: 0] == generation else {
                if let cleanupURL = queueReadyTransfer.cleanupURL {
                    discardedURLs.append(cleanupURL)
                }
                return discardedURLs
            }

            preparedTransfers[scope, default: []].append(queueReadyTransfer)
            var staleURLs = discardedURLs
            let targetCount = effectivePreparedTransferTargetCountLocked(for: scope)
            while preparedTransfers[scope, default: []].count > targetCount {
                guard let removedTransfer = preparedTransfers[scope, default: []].popLast() else {
                    break
                }
                if let cleanupURL = removedTransfer.cleanupURL {
                    staleURLs.append(cleanupURL)
                }
            }
            return staleURLs
        }

        for staleURL in staleURLs {
            try? FileManager.default.removeItem(at: staleURL)
        }

        if queueReadyTransfer != nil {
            schedulePreparedTransferStatePersistence()
        }
        if scope.isPhotoScope {
            publishPreparedPhotoQueueStates()
        }
        ensurePreparedTransfers(for: scope)
    }

    private func removePreparedTransfers(matching assetID: UUID, from scope: ImageSelectionScope) {
        let removal = stateQueue.sync { () -> (removedCount: Int, staleURLs: [URL]) in
            let removedTransfers = preparedTransfers[scope, default: []].filter { $0.asset.id == assetID }
            guard removedTransfers.isEmpty == false else {
                return (0, [])
            }

            preparedTransfers[scope]?.removeAll { $0.asset.id == assetID }
            return (removedTransfers.count, removedTransfers.compactMap(\.cleanupURL))
        }

        for staleURL in removal.staleURLs {
            try? FileManager.default.removeItem(at: staleURL)
        }

        if removal.removedCount > 0 {
            schedulePreparedTransferStatePersistence()
        }
        if scope.isPhotoScope {
            publishPreparedPhotoQueueStates()
        }
    }

    private func invalidatePreparedTransfers(for scope: ImageSelectionScope) {
        let staleURLs = stateQueue.sync {
            preparedTransferGeneration[scope, default: 0] += 1
            preparingTransferCount[scope] = 0
            let urls = preparedTransfers[scope, default: []].compactMap(\.cleanupURL)
            preparedTransfers[scope] = []
            return urls
        }

        for staleURL in staleURLs {
            try? FileManager.default.removeItem(at: staleURL)
        }

        schedulePreparedTransferStatePersistence()
        if scope.isPhotoScope {
            publishPreparedPhotoQueueStates()
        }
    }

    private func restorePreparedTransferStateIfNeeded() {
        let shouldRestore = stateQueue.sync { () -> Bool in
            guard hasRestoredPreparedTransferState == false else {
                return false
            }
            hasRestoredPreparedTransferState = true
            return true
        }
        guard shouldRestore else { return }

        guard FileManager.default.fileExists(atPath: preparedTransferStateURL.path) else {
            return
        }

        do {
            let stateData = try Data(contentsOf: preparedTransferStateURL)
            let persistedState = try JSONDecoder().decode(PersistedPreparedTransferState.self, from: stateData)
            var restoredTransfersByScope: [ImageSelectionScope: [PreparedTransfer]] = [:]

            for persistedScope in persistedState.scopes {
                let restoredTransfers = try persistedScope.transfers.compactMap { persistedTransfer in
                    try restoredPreparedTransfer(from: persistedTransfer)
                }
                let targetCount = configuredPreparedTransferTargetCount(for: persistedScope.scope)
                restoredTransfersByScope[persistedScope.scope] = Array(restoredTransfers.prefix(targetCount))
            }

            stateQueue.sync {
                for persistedScope in persistedState.scopes {
                    let scope = persistedScope.scope
                    let targetCount = effectivePreparedTransferTargetCountLocked(for: scope)
                    preparedTransfers[scope] = Array(restoredTransfersByScope[scope, default: []].prefix(targetCount))
                }
            }

            pruneStalePreparedTransferFiles()
            publishPreparedPhotoQueueStates()
            persistPreparedTransferStateNow()
        } catch {
            updatePublishedState {
                $0.lastError = error.localizedDescription
                $0.appendLog("Failed to restore the warm cache queue: \(error.localizedDescription)")
            }
        }
    }

    private func restoredPreparedTransfer(from persistedTransfer: PersistedPreparedTransfer) throws -> PreparedTransfer? {
        guard let latestAsset = try imageLibraryStore.asset(withID: persistedTransfer.assetID) else {
            return nil
        }
        guard asset(latestAsset, matches: persistedTransfer.scope) else {
            return nil
        }

        let sendURL: URL
        let cleanupURL: URL?
        if let stagedFilename = persistedTransfer.stagedFilename {
            let stagedURL = transferStagingDirectory.appending(path: stagedFilename)
            guard FileManager.default.fileExists(atPath: stagedURL.path) else {
                return nil
            }
            sendURL = stagedURL
            cleanupURL = stagedURL
        } else {
            sendURL = latestAsset.fileURL(relativeTo: imageLibraryStore.rootDirectory)
            cleanupURL = nil
        }

        return PreparedTransfer(
            asset: latestAsset,
            scope: persistedTransfer.scope,
            resourceName: persistedTransfer.resourceName,
            sendURL: sendURL,
            cleanupURL: cleanupURL
        )
    }

    private func schedulePreparedTransferStatePersistence() {
        let shouldSchedule = stateQueue.sync { () -> Bool in
            guard preparedTransferPersistenceScheduled == false else {
                return false
            }
            preparedTransferPersistenceScheduled = true
            return true
        }
        guard shouldSchedule else { return }

        persistenceQueue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.persistPreparedTransferStateNow()
        }
    }

    private func persistPreparedTransferStateNow() {
        let persistedState = stateQueue.sync { () -> PersistedPreparedTransferState in
            preparedTransferPersistenceScheduled = false

            let persistedScopes = preparedTransfers.keys
                .sorted { $0.rawValue < $1.rawValue }
                .map { scope in
                    PersistedPreparedTransferScope(
                        scope: scope,
                        transfers: preparedTransfers[scope, default: []].compactMap { preparedTransfer in
                            persistedPreparedTransfer(from: preparedTransfer)
                        }
                    )
                }

            return PersistedPreparedTransferState(version: 1, scopes: persistedScopes)
        }

        do {
            let encodedState = try JSONEncoder().encode(persistedState)
            try encodedState.write(to: preparedTransferStateURL, options: .atomic)
        } catch {
            updatePublishedState {
                $0.lastError = error.localizedDescription
                $0.appendLog("Failed to persist the warm cache queue: \(error.localizedDescription)")
            }
        }
    }

    private func persistedPreparedTransfer(from preparedTransfer: PreparedTransfer) -> PersistedPreparedTransfer? {
        let stagedFilename = preparedTransfer.cleanupURL?.lastPathComponent
        if let cleanupURL = preparedTransfer.cleanupURL,
           cleanupURL.path.hasPrefix(transferStagingDirectory.path) == false {
            return nil
        }

        return PersistedPreparedTransfer(
            assetID: preparedTransfer.asset.id,
            scope: preparedTransfer.scope,
            resourceName: preparedTransfer.resourceName,
            stagedFilename: stagedFilename
        )
    }

    private func pruneStalePreparedTransferFiles() {
        let referencedFilenames = stateQueue.sync { () -> Set<String> in
            Set(
                preparedTransfers.values
                    .flatMap { $0 }
                    .compactMap { $0.cleanupURL?.lastPathComponent }
            )
        }

        let stagedFileURLs = (try? FileManager.default.contentsOfDirectory(
            at: transferStagingDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        for stagedFileURL in stagedFileURLs where referencedFilenames.contains(stagedFileURL.lastPathComponent) == false {
            try? FileManager.default.removeItem(at: stagedFileURL)
        }
    }

    private func appendLog(_ message: String) {
        let timestamp = DateFormatter.hostActivityFormatter.string(from: Date())
        activityLog.insert("[\(timestamp)] \(message)", at: 0)
        if activityLog.count > 30 {
            activityLog.removeLast(activityLog.count - 30)
        }
    }

    private func publishPreparedPhotoQueueStates() {
        let snapshot = stateQueue.sync { () -> (photoCount: Int, photoTarget: Int, favoriteCount: Int, favoriteTarget: Int) in
            (
                preparedTransfers[.all, default: []].count,
                effectivePreparedTransferTargetCountLocked(for: .all),
                preparedTransfers[.favorites, default: []].count,
                effectivePreparedTransferTargetCountLocked(for: .favorites)
            )
        }

        updatePublishedState {
            $0.preparedPhotoQueueCount = snapshot.photoCount
            $0.preparedPhotoQueueTargetCount = snapshot.photoTarget
            $0.preparedFavoritePhotoQueueCount = snapshot.favoriteCount
            $0.preparedFavoritePhotoQueueTargetCount = snapshot.favoriteTarget
        }
    }

    private func effectivePreparedTransferTargetCountLocked(for scope: ImageSelectionScope) -> Int {
        let configuredTargetCount = configuredPreparedTransferTargetCount(for: scope)
        guard configuredTargetCount > 0 else {
            return 0
        }

        guard let availableAssetCount = try? imageLibraryStore.assetCount(in: scope) else {
            return configuredTargetCount
        }
        guard availableAssetCount > 0 else {
            return 0
        }

        return min(configuredTargetCount, availableAssetCount)
    }

    private func configuredPreparedTransferTargetCount(for scope: ImageSelectionScope) -> Int {
        switch scope {
        case .all:
            preparedPhotoTransferTargetCount
        case .favorites:
            preparedFavoritePhotoTransferTargetCount
        case .videos, .favoriteVideos:
            defaultPreparedTransferTargetCount
        }
    }

    private static func defaultDisplayName() -> String {
        #if os(iOS)
        "Snaplet Host"
        #else
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #endif
    }

    private static func thumbnailAssetID(from resourceName: String) -> UUID? {
        let prefix = "thumbnail-"
        guard resourceName.hasPrefix(prefix) else {
            return nil
        }

        let uuidStartIndex = resourceName.index(resourceName.startIndex, offsetBy: prefix.count)
        guard let uuidEndIndex = resourceName.index(uuidStartIndex, offsetBy: 36, limitedBy: resourceName.endIndex) else {
            return nil
        }

        return UUID(uuidString: String(resourceName[uuidStartIndex..<uuidEndIndex]))
    }

    private func resourceByteSize(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func logDescription(for scope: ImageSelectionScope) -> String {
        switch scope {
        case .all:
            "random photo"
        case .favorites:
            "favorite photo"
        case .videos:
            "random video"
        case .favoriteVideos:
            "favorite video"
        }
    }
}

extension PeerHostService: MCNearbyServiceAdvertiserDelegate {
    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        updatePublishedState {
            $0.lastError = error.localizedDescription
            $0.isAdvertising = false
            $0.connectionStatus = "Advertising failed"
            $0.appendLog("Advertising failed: \(error.localizedDescription)")
        }
    }

    public func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        let reservation = reserveInvitationSlot(for: peerID)

        if reservation.replacedPeerNames.isEmpty == false {
            session.disconnect()
        }

        invitationHandler(true, session)
        updatePublishedState {
            if reservation.replacedPeerNames.isEmpty {
                $0.appendLog("Accepted invitation from \(peerID.displayName).")
            } else {
                $0.appendLog("Replaced \(reservation.replacedPeerNames.joined(separator: ", ")) with \(peerID.displayName).")
            }
        }
    }
}

extension PeerHostService: MCSessionDelegate {
    public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        updatePeerSessionState(state, for: peerID)
        let connectedPeerNames = session.connectedPeers.map(\.displayName)
        let peerName = peerID.displayName
        updatePublishedState {
            $0.connectedPeerNames = connectedPeerNames

            switch state {
            case .notConnected:
                $0.connectionStatus = $0.connectedPeerNames.isEmpty ? "Waiting for iPhone…" : "Connected to \($0.connectedPeerNames.joined(separator: ", "))"
                $0.appendLog("\(peerName) disconnected.")
            case .connecting:
                $0.connectionStatus = "Connecting to \(peerName)…"
                $0.appendLog("Connecting to \(peerName)…")
            case .connected:
                $0.connectionStatus = "Connected to \(peerName)"
                $0.appendLog("\(peerName) connected.")
            @unknown default:
                $0.connectionStatus = "Unknown session state"
            }
        }

        if state == .connected {
            workQueue.async { [weak self] in
                guard let self else { return }

                do {
                    try self.sendLibraryStatus(to: [peerID])
                    self.ensurePreparedTransfers(for: .all)
                    self.ensurePreparedTransfers(for: .favorites)
                    self.ensurePreparedTransfers(for: .videos)
                    self.ensurePreparedTransfers(for: .favoriteVideos)
                } catch {
                    self.updatePublishedState {
                        $0.lastError = error.localizedDescription
                        $0.appendLog("Failed to send library status: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        workQueue.async { [weak self] in
            guard let self else { return }

            do {
                let message = try PeerMessage.decoded(from: data)
                switch message.kind {
                case .requestRandomImage:
                    self.handleRandomImageRequest(
                        from: peerID,
                        purpose: message.requestPurpose ?? .displayNow,
                        scope: message.selectionScope ?? .all
                    )
                case .requestAsset:
                    guard let assetID = message.assetID else {
                        try? self.sendMessage(.failure("Asset request was missing the asset identifier."), to: [peerID])
                        return
                    }
                    self.handleSpecificAssetRequest(
                        assetID: assetID,
                        from: peerID,
                        purpose: message.requestPurpose ?? .displayNow,
                        scope: message.selectionScope ?? .videos
                    )
                case .requestVideoCatalog:
                    self.handleVideoCatalogRequest(
                        from: peerID,
                        scope: message.selectionScope ?? .videos,
                        sort: message.videoCatalogSort ?? .newest
                    )
                case .setFavorite:
                    guard let assetID = message.assetID, let favoriteValue = message.favoriteValue else {
                        try? self.sendMessage(.failure("Favorite update was missing the asset identifier."), to: [peerID])
                        return
                    }
                    self.handleFavoriteUpdate(assetID: assetID, isFavorite: favoriteValue, from: peerID)
                case .deleteAsset:
                    guard let assetID = message.assetID else {
                        try? self.sendMessage(.failure("Delete request was missing the asset identifier."), to: [peerID])
                        return
                    }
                    self.handleDeleteRequest(assetID: assetID, from: peerID)
                case .setVideoThumbnail:
                    guard let assetID = message.assetID,
                          let resourceName = message.thumbnailResourceName else {
                        try? self.sendMessage(.failure("Thumbnail update was missing the asset or resource name."), to: [peerID])
                        return
                    }
                    self.handleSetVideoThumbnail(assetID: assetID, resourceName: resourceName, from: peerID)
                case .libraryStatus, .videoCatalog, .transferReady, .uploadComplete, .favoriteStatusUpdated, .assetDeleted, .videoThumbnailUpdated, .failure:
                    break
                }
            } catch {
                self.updatePublishedState {
                    $0.lastError = error.localizedDescription
                    $0.appendLog("Failed to decode viewer message: \(error.localizedDescription)")
                }
            }
        }
    }

    public func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}

    public func session(
        _ session: MCSession,
        didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        with progress: Progress
    ) {
        let peerName = peerID.displayName
        updatePublishedState {
            $0.appendLog("Receiving upload \(resourceName) from \(peerName)…")
        }
    }

    public func session(
        _ session: MCSession,
        didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        at localURL: URL?,
        withError error: Error?
    ) {
        // MultipeerConnectivity deletes localURL when this callback returns,
        // so copy it to a stable location synchronously before dispatching.
        let stableURL: URL?
        if let localURL, error == nil {
            let dest = FileManager.default.temporaryDirectory
                .appending(path: "snaplet-recv-\(UUID().uuidString)")
            do {
                try FileManager.default.copyItem(at: localURL, to: dest)
                stableURL = dest
            } catch {
                stableURL = nil
            }
        } else {
            stableURL = localURL
        }

        workQueue.async { [weak self] in
            self?.handleIncomingUpload(
                named: resourceName,
                from: peerID,
                localURL: stableURL,
                error: error
            )
            // Clean up the stable copy after import has copied it to the library
            if let stableURL, stableURL != localURL {
                try? FileManager.default.removeItem(at: stableURL)
            }
        }
    }

    public func session(
        _ session: MCSession,
        didReceiveCertificate certificate: [Any]?,
        fromPeer peerID: MCPeerID,
        certificateHandler: @escaping (Bool) -> Void
    ) {
        certificateHandler(true)
    }
}

private extension DateFormatter {
    static let hostActivityFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter
    }()
}
