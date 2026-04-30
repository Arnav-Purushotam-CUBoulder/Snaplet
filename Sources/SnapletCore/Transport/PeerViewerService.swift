import Combine
import AVFoundation
import Foundation
@preconcurrency import MultipeerConnectivity
#if os(iOS)
import ImageIO
import UIKit
public typealias SnapletPlatformImage = UIImage
#elseif os(macOS)
import AppKit
public typealias SnapletPlatformImage = NSImage
#endif

public struct ImageUploadPayload: Sendable {
    public let filename: String
    public let temporaryFileURL: URL
    public let shouldDeleteTemporaryFileAfterStaging: Bool

    public init(
        filename: String,
        temporaryFileURL: URL,
        shouldDeleteTemporaryFileAfterStaging: Bool = true
    ) {
        self.filename = filename
        self.temporaryFileURL = temporaryFileURL
        self.shouldDeleteTemporaryFileAfterStaging = shouldDeleteTemporaryFileAfterStaging
    }
}

private struct ViewerFrame {
    let assetID: UUID
    let mediaType: MediaType
    let image: SnapletPlatformImage?
    let fileURL: URL
    let filename: String
    let byteSize: Int64
    let estimatedMemoryCost: Int64
    let isFavorite: Bool
    let scope: ImageSelectionScope
}

private typealias PendingTransfer = (descriptor: ResourceDescriptor, purpose: ImageRequestPurpose, scope: ImageSelectionScope)

public final class PeerViewerService: NSObject, ObservableObject, @unchecked Sendable {
    private struct PersistedViewerFrame: Codable {
        let assetID: UUID
        let mediaType: MediaType
        let relativeFilePath: String
        let filename: String
        let byteSize: Int64
        let estimatedMemoryCost: Int64
        let isFavorite: Bool
        let scope: ImageSelectionScope
    }

    private struct PersistedViewerState: Codable {
        let version: Int
        let activeSelectionScope: ImageSelectionScope
        let currentFrame: PersistedViewerFrame?
        let previousFrames: [PersistedViewerFrame]
        let forwardFrames: [PersistedViewerFrame]
        let prefetchedFrames: [PersistedViewerFrame]
    }

    private struct NavigationPresentationSnapshot {
        let previousFrame: ViewerFrame?
        let nextFrame: ViewerFrame?
        let queueCount: Int
        let queueTargetCount: Int
        let anyPrefetchInFlight: Bool
    }

    private struct PhotoQueuePresentationSnapshot {
        let photoCount: Int
        let photoTargetCount: Int
        let favoritePhotoCount: Int
        let favoritePhotoTargetCount: Int
    }

    private enum FrameActivationSource {
        case freshContent
        case forwardHistory
        case backwardHistory
    }

    private struct FrameActivationResult {
        let snapshot: NavigationPresentationSnapshot
        let staleURLs: [URL]
    }

    private struct AssetRemovalResult {
        let removedCurrentFrame: ViewerFrame?
        let staleURLs: [URL]
        let snapshot: NavigationPresentationSnapshot
    }

    @Published public private(set) var connectionStatus = "Searching for your Mac…"
    @Published public private(set) var hostName: String?
    @Published public private(set) var libraryCount = 0
    @Published public private(set) var libraryPhotoCount = 0
    @Published public private(set) var libraryVideoCount = 0
    @Published public private(set) var libraryFavoritePhotoCount = 0
    @Published public private(set) var libraryFavoriteVideoCount = 0
    @Published public private(set) var viewedSinceLastOpenCount = 0
    @Published public private(set) var viewedTodayCount = 0
    @Published public private(set) var viewedTodayPhotoCount = 0
    @Published public private(set) var viewedTodayVideoCount = 0
    @Published public private(set) var timeSpentTodaySeconds: TimeInterval = 0
    @Published public private(set) var previousImage: SnapletPlatformImage?
    @Published public private(set) var currentImageURL: URL?
    @Published public private(set) var currentFilename: String?
    @Published public private(set) var currentImage: SnapletPlatformImage?
    @Published public private(set) var currentAssetID: UUID?
    @Published public private(set) var currentMediaType: MediaType?
    @Published public private(set) var currentImageIsFavorite = false
    @Published public private(set) var nextImage: SnapletPlatformImage?
    @Published public private(set) var hasPreviousFrame = false
    @Published public private(set) var hasNextFrame = false
    @Published public private(set) var videoCatalogItems: [VideoCatalogItem] = []
    @Published public private(set) var videoCatalogSort: VideoCatalogSort = .newest
    @Published public private(set) var isLoadingVideoCatalog = false
    @Published public private(set) var isLoadingImage = false
    @Published public private(set) var isPrefetching = false
    @Published public private(set) var isUploadingImages = false
    @Published public private(set) var isUpdatingVideoThumbnail = false
    @Published public private(set) var isUpdatingFavorite = false
    @Published public private(set) var isDeletingImage = false
    @Published public private(set) var isDeletingVideoCatalogItems = false
    @Published public private(set) var activeSelectionScope: ImageSelectionScope = .all
    @Published public private(set) var prefetchQueueCount = 0
    @Published public private(set) var prefetchQueueTargetCount = 0
    @Published public private(set) var photoPrefetchQueueCount = 0
    @Published public private(set) var photoPrefetchQueueTargetCount = 0
    @Published public private(set) var favoritePhotoPrefetchQueueCount = 0
    @Published public private(set) var favoritePhotoPrefetchQueueTargetCount = 0
    @Published public private(set) var uploadStatusMessage: String?
    @Published public private(set) var errorMessage: String?

    private let cacheDirectory: URL
    private let uploadStagingDirectory: URL
    private let persistedStateURL: URL
    private let displayScale: CGFloat
    private let previewImageMaximumPixelSize: Int
    private let peerID: MCPeerID
    private var session: MCSession
    private var browser: MCNearbyServiceBrowser
    private let stateQueue = DispatchQueue(label: "snaplet.viewer.state")
    private let workQueue = DispatchQueue(label: "snaplet.viewer.service", qos: .userInteractive, attributes: .concurrent)
    private let persistenceQueue = DispatchQueue(label: "snaplet.viewer.persistence")
    private let displayDecodeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "snaplet.viewer.decode.display"
        queue.qualityOfService = .userInteractive
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private let prefetchDecodeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "snaplet.viewer.decode.prefetch"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 3
        return queue
    }()
    private let debugAutoUploadPayloads: [ImageUploadPayload]
    private let historyDepth = 5
    private let photoPrefetchTargetDepth = 100
    private let favoritePhotoPrefetchTargetDepth = 50
    private let maxConcurrentPrefetchRequests = 3
    private let prefetchedFrameMemoryBudget: Int64 = 3 * 1024 * 1024 * 1024
    private let defaultPrefetchedFrameMemoryCost: Int64 = 24 * 1024 * 1024
    private let deleteRequestTimeout: TimeInterval = 8
    private var invitedPeerIDs: Set<String> = []
    private var pendingResources: [String: PendingTransfer] = [:]
    private var pendingDeleteAssetID: UUID?
    private var pendingDeleteTimeoutToken: UUID?
    private var receivedResources: [String: URL] = [:]
    private var currentFrameState: ViewerFrame?
    private var previousFrames: [ViewerFrame] = []
    private var forwardFrames: [ViewerFrame] = []
    private var prefetchedFrames: [ViewerFrame] = []
    private var outstandingUploadCount = 0
    private var displayRequestInFlight = false
    private var prefetchRequestsInFlight: [ImageSelectionScope: Int] = [:]
    private var isFeedPrefetchingEnabled = false
    private var hasScheduledDebugAutoUpload = false
    private var isStarted = false
    private var currentSessionState: MCSessionState = .notConnected
    private var activeSelectionScopeState: ImageSelectionScope = .all
    private var recoveryWorkItem: DispatchWorkItem?
    private var lastConnectedAt: Date?
    private var viewerStatePersistenceScheduled = false
    private var hasRestoredPersistedState = false
    private var appUsageTimer: DispatchSourceTimer?
    private var appUsageCheckpointDate: Date?

    @MainActor
    public init(cacheDirectory: URL, displayName: String? = nil, displayScale: CGFloat = 1) {
        self.cacheDirectory = cacheDirectory
        self.uploadStagingDirectory = cacheDirectory.appending(path: "Uploads", directoryHint: .isDirectory)
        self.persistedStateURL = cacheDirectory.appending(path: "viewer-state.json")
        self.displayScale = max(displayScale, 1)
        #if os(iOS)
        let longestEdgeInPoints = max(UIScreen.main.bounds.width, UIScreen.main.bounds.height)
        self.previewImageMaximumPixelSize = max(Int(ceil(longestEdgeInPoints * self.displayScale)), 1)
        #else
        self.previewImageMaximumPixelSize = 1
        #endif
        self.peerID = MCPeerID(displayName: displayName ?? Self.defaultDisplayName())
        self.session = Self.makeSession(for: peerID)
        self.browser = Self.makeBrowser(for: peerID)
        self.debugAutoUploadPayloads = Self.makeDebugAutoUploadPayloads()

        super.init()

        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: uploadStagingDirectory, withIntermediateDirectories: true)
        let viewedTodayCounts = Self.storedViewedTodayCounts()
        self.viewedTodayPhotoCount = viewedTodayCounts.photoCount
        self.viewedTodayVideoCount = viewedTodayCounts.videoCount
        self.viewedTodayCount = viewedTodayCounts.totalCount
        self.timeSpentTodaySeconds = Self.storedTimeSpentTodaySeconds()

        session.delegate = self
        browser.delegate = self
    }

    public func start() {
        stateQueue.sync {
            isStarted = true
        }
        startAppUsageTracking()
        restorePersistedStateIfNeeded()
        beginBrowsing()
        publishViewerStateSnapshot(connectionStatus: "Searching for your Mac…")
    }

    public func stop() {
        stateQueue.sync {
            isStarted = false
            currentSessionState = .notConnected
            recoveryWorkItem?.cancel()
            recoveryWorkItem = nil
        }
        stopAppUsageTracking()
        displayDecodeQueue.cancelAllOperations()
        prefetchDecodeQueue.cancelAllOperations()
        browser.stopBrowsingForPeers()
        session.disconnect()
        resetTransientState(preservingCachedFrames: true)
        persistViewerStateNow()
        publishViewerStateSnapshot(connectionStatus: "Stopped", hostName: nil, updateHostName: true)
    }

    public func requestNextImage(in scope: ImageSelectionScope? = nil) {
        let targetScope = scope ?? currentSelectionScope()
        synchronizeCurrentFrameStateIfNeeded()

        if let forwardFrame = takeForwardFrame(matching: targetScope) {
            promoteHistoryFrame(forwardFrame, source: .forwardHistory)
            maintainParallelPhotoPrefetchPipelines(prioritizing: targetScope)
            return
        }

        if let prefetchedFrame = takePrefetchedFrame(matching: targetScope) {
            promotePrefetchedFrame(prefetchedFrame)
            maintainParallelPhotoPrefetchPipelines(prioritizing: targetScope)
            return
        }

        guard !session.connectedPeers.isEmpty else {
            updatePublishedState {
                $0.errorMessage = "The Mac host is not connected yet."
                $0.connectionStatus = "Still searching for your Mac…"
            }
            return
        }

        requestImage(purpose: .displayNow, scope: targetScope)
    }

    public func requestPreviousImage(in scope: ImageSelectionScope? = nil) {
        let targetScope = scope ?? currentSelectionScope()
        synchronizeCurrentFrameStateIfNeeded()

        guard let previousFrame = takePreviousFrame(matching: targetScope) else { return }
        promoteHistoryFrame(previousFrame, source: .backwardHistory)
    }

    public func requestVideoCatalog(scope: ImageSelectionScope, sort: VideoCatalogSort) {
        let catalogScope: ImageSelectionScope = scope.favoritesOnly ? .favoriteVideos : .videos
        guard !session.connectedPeers.isEmpty else {
            updatePublishedState {
                $0.errorMessage = "Connect to the Mac host before loading videos."
                $0.isLoadingVideoCatalog = false
            }
            return
        }

        updatePublishedState {
            $0.isLoadingVideoCatalog = true
            $0.videoCatalogSort = sort
            $0.errorMessage = nil
        }

        workQueue.async { [weak self] in
            guard let self else { return }

            do {
                try self.session.send(
                    PeerMessage.requestVideoCatalog(scope: catalogScope, sort: sort).encoded(),
                    toPeers: self.session.connectedPeers,
                    with: .reliable
                )
            } catch {
                self.updatePublishedState {
                    $0.isLoadingVideoCatalog = false
                    $0.errorMessage = "Video catalog request failed: \(error.localizedDescription)"
                }
            }
        }
    }

    public func requestVideo(assetID: UUID, in scope: ImageSelectionScope) {
        let targetScope: ImageSelectionScope = scope.favoritesOnly ? .favoriteVideos : .videos
        synchronizeCurrentFrameStateIfNeeded()

        guard !session.connectedPeers.isEmpty else {
            updatePublishedState {
                $0.errorMessage = "The Mac host is not connected yet."
                $0.connectionStatus = "Still searching for your Mac…"
            }
            return
        }

        guard reserveRequestSlot(for: .displayNow, scope: targetScope) else { return }

        do {
            try session.send(
                PeerMessage.requestAsset(assetID: assetID, purpose: .displayNow, scope: targetScope).encoded(),
                toPeers: session.connectedPeers,
                with: .reliable
            )

            updatePublishedState {
                $0.isLoadingImage = true
                $0.errorMessage = nil
            }
        } catch {
            clearRequestFlag(for: .displayNow, scope: targetScope)
            updatePublishedState {
                $0.isLoadingImage = false
                $0.errorMessage = "Video request failed: \(error.localizedDescription)"
            }
        }
    }

    public func setSelectionScope(_ scope: ImageSelectionScope) {
        synchronizeCurrentFrameStateIfNeeded()
        let previousScope = currentSelectionScope()
        let canReuseCurrentImage = currentMediaType == scope.mediaType
            && (!scope.favoritesOnly || currentImageIsFavorite)
        let hadCurrentImage = currentAssetID != nil
        let removedHistoryURLs = discardNavigationHistory()
        let removedCurrentURL = hadCurrentImage && !canReuseCurrentImage ? clearCurrentFrameState() : nil

        setCurrentSelectionScope(scope)
        if canReuseCurrentImage {
            setCurrentFrameScope(scope)
        }
        clearPendingDeleteRequest()
        resetDisplayRequestFlag()
        publishNavigationState()

        updatePublishedState {
            $0.activeSelectionScope = scope
            $0.errorMessage = nil
            $0.isUpdatingFavorite = false
            $0.isDeletingImage = false
            $0.previousImage = nil
            $0.nextImage = nil

            if hadCurrentImage && !canReuseCurrentImage {
                $0.currentImage = nil
                $0.currentImageURL = nil
                $0.currentFilename = nil
            $0.currentAssetID = nil
            $0.currentMediaType = nil
            $0.currentImageIsFavorite = false
            $0.hasPreviousFrame = false
            $0.hasNextFrame = false
            $0.isLoadingImage = false
            }
        }

        for removedHistoryURL in removedHistoryURLs {
            removeCachedMediaIfNeeded(at: removedHistoryURL)
        }
        if let removedCurrentURL {
            removeCachedMediaIfNeeded(at: removedCurrentURL)
        }
        scheduleViewerStatePersistence()

        let shouldLoadImmediately = previousScope != scope
            ? (!hadCurrentImage || !canReuseCurrentImage)
            : currentAssetID == nil && !isLoadingImage

        if shouldLoadImmediately && scope.mediaType == .photo {
            requestNextImage(in: scope)
        } else {
            maintainParallelPhotoPrefetchPipelines(prioritizing: scope)
        }
    }

    public func setFeedPrefetchingEnabled(_ enabled: Bool) {
        let didChange = stateQueue.sync { () -> Bool in
            guard isFeedPrefetchingEnabled != enabled else { return false }
            isFeedPrefetchingEnabled = enabled
            return true
        }

        guard didChange else { return }

        if enabled == false {
            prefetchDecodeQueue.cancelAllOperations()
            publishNavigationState()
            return
        }

        maintainParallelPhotoPrefetchPipelines(prioritizing: currentSelectionScope())
    }

    public func toggleFavorite() {
        guard let assetID = currentAssetID else { return }
        guard !session.connectedPeers.isEmpty else {
            updatePublishedState {
                $0.errorMessage = "Connect to the Mac host before changing favorites."
            }
            return
        }

        let nextFavoriteValue = !currentImageIsFavorite
        updatePublishedState {
            $0.isUpdatingFavorite = true
            $0.errorMessage = nil
        }

        workQueue.async { [weak self] in
            guard let self else { return }

            do {
                try self.session.send(
                    PeerMessage.setFavorite(assetID: assetID, isFavorite: nextFavoriteValue).encoded(),
                    toPeers: self.session.connectedPeers,
                    with: .reliable
                )
            } catch {
                self.updatePublishedState {
                    $0.isUpdatingFavorite = false
                    $0.errorMessage = "Favorite update failed: \(error.localizedDescription)"
                }
            }
        }
    }

    public func deleteCurrentImage() {
        guard let assetID = currentAssetID else { return }
        guard !session.connectedPeers.isEmpty else {
            updatePublishedState {
                $0.errorMessage = "Connect to the Mac host before deleting media."
            }
            return
        }

        updatePublishedState {
            $0.isDeletingImage = true
            $0.errorMessage = nil
        }
        scheduleDeleteTimeout(for: assetID)

        workQueue.async { [weak self] in
            guard let self else { return }

            do {
                try self.session.send(
                    PeerMessage.deleteAsset(assetID: assetID).encoded(),
                    toPeers: self.session.connectedPeers,
                    with: .reliable
                )
            } catch {
                self.clearPendingDeleteRequest(matching: assetID)
                self.updatePublishedState {
                    $0.isDeletingImage = false
                    $0.errorMessage = "Delete failed: \(error.localizedDescription)"
                }
            }
        }
    }

    public func deleteVideoCatalogItems(assetIDs: [UUID]) {
        let uniqueAssetIDs = Array(Set(assetIDs))
        guard !uniqueAssetIDs.isEmpty else { return }
        guard !session.connectedPeers.isEmpty else {
            updatePublishedState {
                $0.errorMessage = "Connect to the Mac host before deleting videos."
                $0.isDeletingVideoCatalogItems = false
            }
            return
        }

        updatePublishedState {
            $0.isDeletingVideoCatalogItems = true
            $0.errorMessage = nil
        }

        workQueue.async { [weak self] in
            guard let self else { return }

            do {
                for assetID in uniqueAssetIDs {
                    try self.session.send(
                        PeerMessage.deleteAsset(assetID: assetID).encoded(),
                        toPeers: self.session.connectedPeers,
                        with: .reliable
                    )
                }

                self.updatePublishedState {
                    $0.isDeletingVideoCatalogItems = false
                }
            } catch {
                self.updatePublishedState {
                    $0.isDeletingVideoCatalogItems = false
                    $0.errorMessage = "Video delete failed: \(error.localizedDescription)"
                }
            }
        }
    }

    public func restartDiscovery() {
        cancelScheduledRecovery()
        rebuildTransportStack(disconnectCurrentSession: true)
        beginBrowsing()
        updatePublishedState {
            $0.errorMessage = nil
            $0.uploadStatusMessage = nil
            $0.connectionStatus = "Searching for your Mac…"
        }
    }

    public func uploadImages(_ payloads: [ImageUploadPayload]) {
        guard !payloads.isEmpty else { return }

        guard let hostPeer = session.connectedPeers.first else {
            updatePublishedState {
                $0.errorMessage = "Connect to the Mac host before uploading media."
                $0.uploadStatusMessage = nil
            }
            return
        }

        addOutstandingUploads(payloads.count)
        updatePublishedState {
            $0.isUploadingImages = true
            $0.uploadStatusMessage = "Uploading \(payloads.count) item\((payloads.count == 1) ? "" : "s") to your Mac…"
            $0.errorMessage = nil
        }

        for payload in payloads {
            workQueue.async { [weak self] in
                self?.stageAndUpload(payload, to: hostPeer)
            }
        }
    }

    public func uploadVideoThumbnail(assetID: UUID, payload: ImageUploadPayload) {
        guard let hostPeer = session.connectedPeers.first else {
            updatePublishedState {
                $0.errorMessage = "Connect to the Mac host before updating thumbnails."
                $0.isUpdatingVideoThumbnail = false
            }
            return
        }

        updatePublishedState {
            $0.isUpdatingVideoThumbnail = true
            $0.uploadStatusMessage = "Uploading video thumbnail…"
            $0.errorMessage = nil
        }

        workQueue.async { [weak self] in
            guard let self else { return }

            let safeFilename = payload.filename.replacingOccurrences(of: "/", with: "-")
            let resourceName = "thumbnail-\(assetID.uuidString)-\(UUID().uuidString)-\(safeFilename)"
            let fileURL = self.uploadStagingDirectory.appending(path: resourceName)

            do {
                defer {
                    if payload.shouldDeleteTemporaryFileAfterStaging {
                        try? FileManager.default.removeItem(at: payload.temporaryFileURL)
                    }
                }

                if FileManager.default.fileExists(atPath: fileURL.path) {
                    try FileManager.default.removeItem(at: fileURL)
                }
                try FileManager.default.copyItem(at: payload.temporaryFileURL, to: fileURL)

                try self.session.send(
                    PeerMessage.setVideoThumbnail(assetID: assetID, resourceName: resourceName).encoded(),
                    toPeers: [hostPeer],
                    with: .reliable
                )

                self.session.sendResource(at: fileURL, withName: resourceName, toPeer: hostPeer) { [weak self] error in
                    try? FileManager.default.removeItem(at: fileURL)
                    guard let self else { return }

                    if let error {
                        self.updatePublishedState {
                            $0.isUpdatingVideoThumbnail = false
                            $0.uploadStatusMessage = nil
                            $0.errorMessage = "Thumbnail upload failed: \(error.localizedDescription)"
                        }
                    } else {
                        self.updatePublishedState {
                            $0.uploadStatusMessage = "Thumbnail sent. Waiting for your Mac to save it…"
                        }
                    }
                }
            } catch {
                try? FileManager.default.removeItem(at: fileURL)
                self.updatePublishedState {
                    $0.isUpdatingVideoThumbnail = false
                    $0.uploadStatusMessage = nil
                    $0.errorMessage = "Failed to prepare thumbnail: \(error.localizedDescription)"
                }
            }
        }
    }

    private func requestImage(purpose: ImageRequestPurpose, scope: ImageSelectionScope) {
        guard !session.connectedPeers.isEmpty else { return }
        guard reserveRequestSlot(for: purpose, scope: scope) else { return }

        do {
            try session.send(
                PeerMessage.requestRandomImage(purpose: purpose, scope: scope).encoded(),
                toPeers: session.connectedPeers,
                with: .reliable
            )

            updatePublishedState {
                $0.errorMessage = nil

                switch purpose {
                case .displayNow:
                    $0.isLoadingImage = true
                case .prefetch:
                    $0.isPrefetching = true
                }
            }
        } catch {
            clearRequestFlag(for: purpose, scope: scope)
            updatePublishedState {
                $0.errorMessage = error.localizedDescription
                $0.connectionStatus = "Request failed"
                $0.isLoadingImage = false
            }
            publishNavigationState()
        }
    }

    private func maintainPrefetchPipeline(
        for scope: ImageSelectionScope? = nil,
        allowInactiveScope: Bool = false
    ) {
        let targetScope = scope ?? currentSelectionScope()
        guard allowInactiveScope || targetScope == currentSelectionScope() else { return }
        guard !session.connectedPeers.isEmpty else { return }
        let requestBatchSize = nextPrefetchRequestBatchSize(for: targetScope)
        guard requestBatchSize > 0 else { return }

        for _ in 0..<requestBatchSize {
            requestImage(purpose: .prefetch, scope: targetScope)
        }
    }

    private func maintainParallelPhotoPrefetchPipelines(prioritizing primaryScope: ImageSelectionScope? = nil) {
        let prioritizedScopes = prioritizedParallelPhotoScopes(primaryScope ?? currentSelectionScope())
        for scope in prioritizedScopes {
            maintainPrefetchPipeline(for: scope, allowInactiveScope: true)
        }
    }

    private func prioritizedParallelPhotoScopes(_ primaryScope: ImageSelectionScope) -> [ImageSelectionScope] {
        switch primaryScope {
        case .favorites:
            [.favorites, .all]
        case .all:
            [.all, .favorites]
        case .videos, .favoriteVideos:
            [.all, .favorites]
        }
    }

    private func promotePrefetchedFrame(_ frame: ViewerFrame) {
        let activation = activateFrameInState(frame, source: .freshContent)
        recordViewedMedia(mediaType: frame.mediaType)

        updatePublishedState {
            $0.previousImage = activation.snapshot.previousFrame?.image
            $0.currentImage = frame.image
            $0.currentImageURL = frame.fileURL
            $0.currentFilename = frame.filename
            $0.currentAssetID = frame.assetID
            $0.currentMediaType = frame.mediaType
            $0.currentImageIsFavorite = frame.isFavorite
            $0.nextImage = activation.snapshot.nextFrame?.image
            $0.hasPreviousFrame = activation.snapshot.previousFrame != nil
            $0.hasNextFrame = activation.snapshot.nextFrame != nil
            $0.isLoadingImage = false
            $0.errorMessage = nil
            $0.isPrefetching = activation.snapshot.anyPrefetchInFlight
            $0.prefetchQueueCount = activation.snapshot.queueCount
            $0.prefetchQueueTargetCount = activation.snapshot.queueTargetCount
        }

        for staleURL in activation.staleURLs where staleURL != frame.fileURL {
            removeCachedMediaIfNeeded(at: staleURL)
        }

        scheduleViewerStatePersistence()
        publishPhotoPrefetchQueueStates()
    }

    private func stageAndUpload(_ payload: ImageUploadPayload, to hostPeer: MCPeerID) {
        let safeFilename = payload.filename.replacingOccurrences(of: "/", with: "-")
        let fileURL = uploadStagingDirectory.appending(path: "\(UUID().uuidString)-\(safeFilename)")

        do {
            defer {
                if payload.shouldDeleteTemporaryFileAfterStaging {
                    try? FileManager.default.removeItem(at: payload.temporaryFileURL)
                }
            }

            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            try FileManager.default.copyItem(at: payload.temporaryFileURL, to: fileURL)

            session.sendResource(at: fileURL, withName: safeFilename, toPeer: hostPeer) { [weak self] error in
                try? FileManager.default.removeItem(at: fileURL)
                guard let self else { return }

                if let error {
                    let remainingUploads = self.completeOneOutstandingUpload()
                    self.updatePublishedState {
                        $0.errorMessage = "Upload failed for \(safeFilename): \(error.localizedDescription)"
                        $0.uploadStatusMessage = remainingUploads == 0 ? nil : $0.uploadStatusMessage
                        $0.isUploadingImages = remainingUploads > 0
                    }
                } else {
                    self.updatePublishedState {
                        $0.uploadStatusMessage = self.outstandingUploadCountValue() == 0
                            ? "Upload sent to your Mac."
                            : "Transfer sent. Waiting for your Mac to finish indexing…"
                    }
                }
            }
        } catch {
            let remainingUploads = completeOneOutstandingUpload()
            updatePublishedState {
                $0.errorMessage = "Failed to prepare \(safeFilename) for upload: \(error.localizedDescription)"
                $0.isUploadingImages = remainingUploads > 0
                if remainingUploads == 0 {
                    $0.uploadStatusMessage = nil
                }
            }
        }
    }

    private func scheduleDebugAutoUploadIfNeeded() -> Bool {
        guard !debugAutoUploadPayloads.isEmpty else { return false }

        let shouldSchedule = stateQueue.sync {
            guard !hasScheduledDebugAutoUpload else { return false }
            hasScheduledDebugAutoUpload = true
            return true
        }

        guard shouldSchedule else { return false }

        workQueue.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            guard let self else { return }
            self.uploadImages(self.debugAutoUploadPayloads)
        }

        return true
    }

    private func handleMessage(_ message: PeerMessage) {
        switch message.kind {
        case .libraryStatus:
            if let summary = message.librarySummary {
                updatePublishedLibrarySummary(summary)
                return
            }
            updatePublishedState {
                $0.libraryCount = message.libraryCount ?? 0
            }
        case .videoCatalog:
            updatePublishedState {
                $0.videoCatalogItems = message.videoCatalogItems ?? []
                $0.videoCatalogSort = message.videoCatalogSort ?? $0.videoCatalogSort
                $0.isLoadingVideoCatalog = false
                $0.errorMessage = nil
            }
        case .transferReady:
            guard let resource = message.resource else { return }

            let purpose = message.requestPurpose ?? .displayNow
            let scope = message.selectionScope ?? .all
            let activeScope = currentSelectionScope()

            if scope == activeScope {
                updatePublishedState {
                    if purpose == .displayNow {
                        $0.isLoadingImage = true
                    } else {
                        $0.isPrefetching = true
                    }
                }
            }

            if resource.mediaType == .video, let streamURL = resource.streamURL {
                processStreamedResource(
                    at: streamURL,
                    pendingTransfer: (descriptor: resource, purpose: purpose, scope: scope)
                )
                return
            }

            let readyURL = registerTransferDescriptor(resource, purpose: purpose, scope: scope)
            if let readyURL {
                processReceivedResource(
                    at: readyURL,
                    pendingTransfer: (descriptor: resource, purpose: purpose, scope: scope)
                )
            }
        case .uploadComplete:
            guard let resource = message.resource else { return }
            let remainingUploads = completeOneOutstandingUpload()
            let shouldAutoRequestDebugImage = debugAutoUploadPayloads.isEmpty == false
                && remainingUploads == 0
                && currentAssetID == nil

            updatePublishedState {
                $0.libraryCount = message.libraryCount ?? $0.libraryCount
                $0.uploadStatusMessage = "Uploaded \(resource.originalFilename) to your Mac."
                $0.isUploadingImages = remainingUploads > 0
            }

            if shouldAutoRequestDebugImage {
                workQueue.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    self?.requestNextImage()
                }
            }
            if resource.mediaType == .video {
                requestVideoCatalog(scope: currentSelectionScope(), sort: videoCatalogSort)
            }
        case .favoriteStatusUpdated:
            guard let assetID = message.assetID, let favoriteValue = message.favoriteValue else { return }
            updateVideoCatalogFavorite(assetID: assetID, isFavorite: favoriteValue)
            handleFavoriteStatusUpdate(assetID: assetID, isFavorite: favoriteValue)
        case .assetDeleted:
            guard let assetID = message.assetID else { return }
            removeVideoCatalogItem(assetID: assetID)
            handleDeletedAsset(assetID: assetID, libraryCount: message.libraryCount)
        case .videoThumbnailUpdated:
            guard message.assetID != nil else { return }
            let activeScope = currentSelectionScope()
            updatePublishedState {
                $0.isUpdatingVideoThumbnail = false
                $0.uploadStatusMessage = "Video thumbnail updated."
                $0.errorMessage = nil
            }
            if activeScope.mediaType == .video {
                requestVideoCatalog(scope: activeScope, sort: videoCatalogSort)
            }
        case .failure:
            clearPendingDeleteRequest()
            resetDisplayRequestFlag()
            clearAllPrefetchRequestFlags()
            updatePublishedState {
                $0.isLoadingImage = false
                $0.isLoadingVideoCatalog = false
                $0.isUpdatingVideoThumbnail = false
                $0.isUpdatingFavorite = false
                $0.isDeletingImage = false
                $0.isDeletingVideoCatalogItems = false
                $0.errorMessage = message.errorMessage
                $0.connectionStatus = "Request failed"
            }
            publishNavigationState()
        case .requestRandomImage, .requestAsset, .requestVideoCatalog, .setFavorite, .deleteAsset, .setVideoThumbnail:
            break
        }
    }

    private func completeResourceTransfer(resourceName: String, localURL: URL?, error: Error?) {
        if let error {
            clearRequestFlagsForResource(named: resourceName)
            updatePublishedState {
                $0.isLoadingImage = false
                $0.errorMessage = error.localizedDescription
                $0.connectionStatus = "Transfer failed"
            }
            publishNavigationState()
            return
        }

        guard let localURL else {
            clearRequestFlagsForResource(named: resourceName)
            updatePublishedState {
                $0.isLoadingImage = false
                $0.errorMessage = "The host finished a transfer without a file URL."
                $0.connectionStatus = "Transfer failed"
            }
            publishNavigationState()
            return
        }

        do {
            let destinationURL = try relocateReceivedResource(at: localURL, named: resourceName)

            if let pendingTransfer = registerReceivedResource(at: destinationURL, named: resourceName) {
                processReceivedResource(at: destinationURL, pendingTransfer: pendingTransfer)
            }
        } catch {
            clearRequestFlagsForResource(named: resourceName)
            updatePublishedState {
                $0.isLoadingImage = false
                $0.errorMessage = error.localizedDescription
                $0.connectionStatus = "Transfer failed"
            }
            publishNavigationState()
        }
    }

    private func relocateReceivedResource(at localURL: URL, named resourceName: String) throws -> URL {
        let destinationURL = cacheDirectory.appending(path: resourceName)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        do {
            try FileManager.default.moveItem(at: localURL, to: destinationURL)
        } catch {
            // Fall back to copy+delete if the transfer service hands us a URL that cannot be renamed in place.
            try FileManager.default.copyItem(at: localURL, to: destinationURL)
            try? FileManager.default.removeItem(at: localURL)
        }

        return destinationURL
    }

    private func processReceivedResource(at fileURL: URL, pendingTransfer: PendingTransfer) {
        let targetQueue = pendingTransfer.purpose == .displayNow ? displayDecodeQueue : prefetchDecodeQueue
        targetQueue.addOperation { [weak self] in
            guard let self else { return }
            guard !targetQueue.isSuspended else { return }

            let previewImage = self.decodePreviewImage(
                at: fileURL,
                mediaType: pendingTransfer.descriptor.mediaType
            )

            if pendingTransfer.descriptor.mediaType == .photo, previewImage == nil {
                self.clearRequestFlag(for: pendingTransfer.purpose, scope: pendingTransfer.scope)
                self.updatePublishedState {
                    $0.isLoadingImage = false
                    $0.errorMessage = "Failed to decode \(pendingTransfer.descriptor.originalFilename)."
                    $0.connectionStatus = "Decode failed"
                }
                self.publishNavigationState()
                return
            }

            let frame = ViewerFrame(
                assetID: pendingTransfer.descriptor.assetID,
                mediaType: pendingTransfer.descriptor.mediaType,
                image: previewImage,
                fileURL: fileURL,
                filename: pendingTransfer.descriptor.originalFilename,
                byteSize: pendingTransfer.descriptor.byteSize,
                estimatedMemoryCost: self.estimatedMemoryCost(for: previewImage),
                isFavorite: pendingTransfer.descriptor.isFavorite,
                scope: pendingTransfer.scope
            )

            let activeScope = self.currentSelectionScope()
            switch pendingTransfer.purpose {
            case .displayNow:
                guard frame.scope == activeScope else {
                    self.clearRequestFlag(for: .displayNow, scope: pendingTransfer.scope)
                    if self.shouldAcceptPrefetchedFrame(in: frame.scope) {
                        self.storePrefetchedFrame(frame)
                    } else {
                        self.publishNavigationState()
                        self.removeCachedMediaIfNeeded(at: fileURL)
                    }
                    return
                }

                self.promoteDecodedFrame(frame)
                self.maintainParallelPhotoPrefetchPipelines(prioritizing: frame.scope)
            case .prefetch:
                guard self.shouldAcceptPrefetchedFrame(in: frame.scope) else {
                    self.clearRequestFlag(for: .prefetch, scope: pendingTransfer.scope)
                    self.publishNavigationState()
                    self.removeCachedMediaIfNeeded(at: fileURL)
                    return
                }

                self.storePrefetchedFrame(frame)
            }
        }
    }

    private func processStreamedResource(at streamURL: URL, pendingTransfer: PendingTransfer) {
        let frame = ViewerFrame(
            assetID: pendingTransfer.descriptor.assetID,
            mediaType: pendingTransfer.descriptor.mediaType,
            image: nil,
            fileURL: streamURL,
            filename: pendingTransfer.descriptor.originalFilename,
            byteSize: pendingTransfer.descriptor.byteSize,
            estimatedMemoryCost: defaultPrefetchedFrameMemoryCost,
            isFavorite: pendingTransfer.descriptor.isFavorite,
            scope: pendingTransfer.scope
        )

        let activeScope = currentSelectionScope()
        switch pendingTransfer.purpose {
        case .displayNow:
            guard frame.scope == activeScope else {
                clearRequestFlag(for: .displayNow, scope: pendingTransfer.scope)
                publishNavigationState()
                return
            }

            promoteDecodedFrame(frame)
            maintainParallelPhotoPrefetchPipelines(prioritizing: frame.scope)
        case .prefetch:
            guard shouldAcceptPrefetchedFrame(in: frame.scope) else {
                clearRequestFlag(for: .prefetch, scope: pendingTransfer.scope)
                publishNavigationState()
                return
            }

            storePrefetchedFrame(frame)
        }
    }

    private func promoteDecodedFrame(_ frame: ViewerFrame) {
        clearRequestFlag(for: .displayNow, scope: frame.scope)
        let activation = activateFrameInState(frame, source: .freshContent)
        recordViewedMedia(mediaType: frame.mediaType)

        updatePublishedState {
            $0.previousImage = activation.snapshot.previousFrame?.image
            $0.currentImage = frame.image
            $0.currentImageURL = frame.fileURL
            $0.currentFilename = frame.filename
            $0.currentAssetID = frame.assetID
            $0.currentMediaType = frame.mediaType
            $0.currentImageIsFavorite = frame.isFavorite
            $0.nextImage = activation.snapshot.nextFrame?.image
            $0.hasPreviousFrame = activation.snapshot.previousFrame != nil
            $0.hasNextFrame = activation.snapshot.nextFrame != nil
            $0.isLoadingImage = false
            $0.isPrefetching = activation.snapshot.anyPrefetchInFlight
            $0.prefetchQueueCount = activation.snapshot.queueCount
            $0.prefetchQueueTargetCount = activation.snapshot.queueTargetCount
            $0.errorMessage = nil
        }

        for staleURL in activation.staleURLs where staleURL != frame.fileURL {
            removeCachedMediaIfNeeded(at: staleURL)
        }

        scheduleViewerStatePersistence()
        publishPhotoPrefetchQueueStates()
    }

    private func storePrefetchedFrame(_ frame: ViewerFrame) {
        let removedPrefetchedURLs = storePrefetchedFrameInState(frame)
        let navigationSnapshot = navigationPresentationSnapshot()

        updatePublishedState {
            $0.previousImage = navigationSnapshot.previousFrame?.image
            $0.nextImage = navigationSnapshot.nextFrame?.image
            $0.hasPreviousFrame = navigationSnapshot.previousFrame != nil
            $0.hasNextFrame = navigationSnapshot.nextFrame != nil
            $0.isPrefetching = navigationSnapshot.anyPrefetchInFlight
            $0.prefetchQueueCount = navigationSnapshot.queueCount
            $0.prefetchQueueTargetCount = navigationSnapshot.queueTargetCount
        }

        for previousPrefetchedURL in removedPrefetchedURLs where previousPrefetchedURL != frame.fileURL {
            removeCachedMediaIfNeeded(at: previousPrefetchedURL)
        }

        scheduleViewerStatePersistence()
        publishPhotoPrefetchQueueStates()
        maintainParallelPhotoPrefetchPipelines(prioritizing: frame.scope)
    }

    private func updatePublishedState(_ update: @Sendable @escaping (PeerViewerService) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            update(self)
        }
    }

    private func removeCachedMediaIfNeeded(at url: URL) {
        guard url.isFileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func reserveRequestSlot(for purpose: ImageRequestPurpose, scope: ImageSelectionScope) -> Bool {
        stateQueue.sync {
            switch purpose {
            case .displayNow:
                guard !displayRequestInFlight else { return false }
                displayRequestInFlight = true
                return true
            case .prefetch:
                let queuedPrefetches = prefetchedFrames.filter { $0.scope == scope }.count
                let inFlightPrefetches = prefetchRequestsInFlight[scope, default: 0]
                let effectiveTargetDepth = effectivePrefetchTargetDepthLocked(for: scope)
                guard queuedPrefetches + inFlightPrefetches < effectiveTargetDepth else { return false }
                guard inFlightPrefetches < maxConcurrentPrefetchRequests else { return false }
                prefetchRequestsInFlight[scope, default: 0] = inFlightPrefetches + 1
                return true
            }
        }
    }

    private func clearRequestFlag(for purpose: ImageRequestPurpose, scope: ImageSelectionScope) {
        stateQueue.sync {
            switch purpose {
            case .displayNow:
                displayRequestInFlight = false
            case .prefetch:
                prefetchRequestsInFlight[scope] = max(0, prefetchRequestsInFlight[scope, default: 0] - 1)
            }
        }
    }

    private func resetDisplayRequestFlag() {
        stateQueue.sync {
            displayRequestInFlight = false
        }
    }

    private func clearAllPrefetchRequestFlags() {
        stateQueue.sync {
            prefetchRequestsInFlight.removeAll()
        }
    }

    private func shouldAcceptPrefetchedFrame(in scope: ImageSelectionScope) -> Bool {
        stateQueue.sync {
            isFeedPrefetchingEnabled && effectivePrefetchTargetDepthLocked(for: scope) > 0
        }
    }

    private func registerTransferDescriptor(
        _ descriptor: ResourceDescriptor,
        purpose: ImageRequestPurpose,
        scope: ImageSelectionScope
    ) -> URL? {
        stateQueue.sync {
            if let receivedURL = receivedResources.removeValue(forKey: descriptor.resourceName) {
                return receivedURL
            }

            pendingResources[descriptor.resourceName] = (descriptor, purpose, scope)
            return nil
        }
    }

    private func registerReceivedResource(at url: URL, named resourceName: String) -> PendingTransfer? {
        stateQueue.sync {
            if let pendingTransfer = pendingResources.removeValue(forKey: resourceName) {
                return pendingTransfer
            }

            receivedResources[resourceName] = url
            return nil
        }
    }

    private func clearRequestFlagsForResource(named resourceName: String) {
        stateQueue.sync {
            if let pendingTransfer = pendingResources.removeValue(forKey: resourceName) {
                switch pendingTransfer.purpose {
                case .displayNow:
                    displayRequestInFlight = false
                case .prefetch:
                    prefetchRequestsInFlight[pendingTransfer.scope] = max(
                        0,
                        prefetchRequestsInFlight[pendingTransfer.scope, default: 0] - 1
                    )
                }
            }

            if let receivedURL = receivedResources.removeValue(forKey: resourceName) {
                removeCachedMediaIfNeeded(at: receivedURL)
            }
        }
    }

    private func takePrefetchedFrame(matching scope: ImageSelectionScope) -> ViewerFrame? {
        stateQueue.sync {
            guard let matchingIndex = prefetchedFrames.firstIndex(where: { $0.scope == scope }) else {
                return nil
            }
            return prefetchedFrames.remove(at: matchingIndex)
        }
    }

    private func prefetchPipelineDeficit(for scope: ImageSelectionScope) -> Int {
        stateQueue.sync {
            let queuedCount = prefetchedFrames.filter { $0.scope == scope }.count
            let inFlightCount = prefetchRequestsInFlight[scope, default: 0]
            let effectiveTargetDepth = effectivePrefetchTargetDepthLocked(for: scope)
            return max(effectiveTargetDepth - (queuedCount + inFlightCount), 0)
        }
    }

    private func nextPrefetchRequestBatchSize(for scope: ImageSelectionScope) -> Int {
        stateQueue.sync {
            guard isFeedPrefetchingEnabled else { return 0 }
            let queuedCount = prefetchedFrames.filter { $0.scope == scope }.count
            let inFlightCount = prefetchRequestsInFlight[scope, default: 0]
            let effectiveTargetDepth = effectivePrefetchTargetDepthLocked(for: scope)
            let deficit = max(effectiveTargetDepth - (queuedCount + inFlightCount), 0)
            let availableConcurrency = max(maxConcurrentPrefetchRequests - inFlightCount, 0)
            return min(deficit, availableConcurrency)
        }
    }

    private func storePrefetchedFrameInState(_ frame: ViewerFrame) -> [URL] {
        stateQueue.sync {
            prefetchRequestsInFlight[frame.scope] = max(0, prefetchRequestsInFlight[frame.scope, default: 0] - 1)

            prefetchedFrames.append(frame)

            var removedURLs: [URL] = []
            let effectiveTargetDepth = effectivePrefetchTargetDepthLocked(for: frame.scope)
            while prefetchedFrames.filter({ $0.scope == frame.scope }).count > effectiveTargetDepth
                || (prefetchedFrameMemoryUsageLocked(for: frame.scope) > prefetchedFrameMemoryBudget
                    && prefetchedFrames.filter({ $0.scope == frame.scope }).count > 1) {
                guard let removalIndex = prefetchedFrames.indices.last(where: { prefetchedFrames[$0].scope == frame.scope }) else {
                    break
                }
                removedURLs.append(prefetchedFrames.remove(at: removalIndex).fileURL)
            }

            return removedURLs
        }
    }

    private func prefetchedFrameMemoryUsageLocked(for scope: ImageSelectionScope) -> Int64 {
        prefetchedFrames
            .filter { $0.scope == scope }
            .reduce(into: Int64(0)) { partialResult, frame in
                partialResult += frame.estimatedMemoryCost
            }
    }

    private func approximatePrefetchedFrameMemoryCostLocked(for scope: ImageSelectionScope) -> Int64 {
        let scopedFrames = prefetchedFrames.filter { $0.scope == scope }
        if scopedFrames.isEmpty == false {
            let byteSum = scopedFrames.reduce(into: Int64(0)) { partialResult, frame in
                partialResult += frame.estimatedMemoryCost
            }
            return max(byteSum / Int64(scopedFrames.count), defaultPrefetchedFrameMemoryCost)
        }

        if let currentFrameState, currentFrameState.scope == scope {
            return max(currentFrameState.estimatedMemoryCost, defaultPrefetchedFrameMemoryCost)
        }

        return defaultPrefetchedFrameMemoryCost
    }

    private func effectivePrefetchTargetDepthLocked(for scope: ImageSelectionScope) -> Int {
        // Videos should not use file-based prefetching because the current transport
        // delivers whole resources before playback begins.
        if scope.mediaType == .video {
            return 0
        }

        let exemplarMemoryCost = max(approximatePrefetchedFrameMemoryCostLocked(for: scope), 1)
        let memoryBoundTarget = max(Int(prefetchedFrameMemoryBudget / exemplarMemoryCost), 1)
        let configuredTarget = scope.favoritesOnly ? favoritePhotoPrefetchTargetDepth : photoPrefetchTargetDepth
        return min(configuredTarget, memoryBoundTarget)
    }

    private func updatePublishedLibrarySummary(_ summary: LibrarySummary) {
        updatePublishedState {
            $0.libraryCount = summary.assetCount
            $0.libraryPhotoCount = summary.photoCount
            $0.libraryVideoCount = summary.videoCount
            $0.libraryFavoritePhotoCount = summary.favoritePhotoCount
            $0.libraryFavoriteVideoCount = summary.favoriteVideoCount
        }
    }

    private func recordViewedMedia(mediaType: MediaType) {
        let todayCounts = Self.incrementStoredViewedTodayCount(for: mediaType)
        updatePublishedState {
            $0.viewedSinceLastOpenCount += 1
            $0.viewedTodayPhotoCount = todayCounts.photoCount
            $0.viewedTodayVideoCount = todayCounts.videoCount
            $0.viewedTodayCount = todayCounts.totalCount
        }
    }

    private func startAppUsageTracking() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 30)
        timer.setEventHandler { [weak self] in
            self?.checkpointAppUsageTracking(ending: false)
        }

        let previousTimer = stateQueue.sync { () -> DispatchSourceTimer? in
            let previousTimer = appUsageTimer
            appUsageTimer = timer
            appUsageCheckpointDate = Date()
            return previousTimer
        }
        previousTimer?.setEventHandler {}
        previousTimer?.cancel()

        timer.resume()
        checkpointAppUsageTracking(ending: false)
    }

    private func stopAppUsageTracking() {
        let timer = stateQueue.sync { () -> DispatchSourceTimer? in
            let timer = appUsageTimer
            appUsageTimer = nil
            return timer
        }
        timer?.setEventHandler {}
        timer?.cancel()
        checkpointAppUsageTracking(ending: true)
    }

    private func checkpointAppUsageTracking(ending: Bool) {
        let now = Date()
        let elapsedSeconds = stateQueue.sync { () -> TimeInterval in
            guard let checkpointDate = appUsageCheckpointDate else {
                if ending == false {
                    appUsageCheckpointDate = now
                }
                return 0
            }

            if ending {
                appUsageCheckpointDate = nil
            } else {
                appUsageCheckpointDate = now
            }
            return max(now.timeIntervalSince(checkpointDate), 0)
        }

        let totalSeconds = Self.addStoredTimeSpentTodaySeconds(elapsedSeconds)
        updatePublishedState {
            $0.timeSpentTodaySeconds = totalSeconds
        }
    }

    private func addOutstandingUploads(_ count: Int) {
        stateQueue.sync {
            outstandingUploadCount += count
        }
    }

    private func completeOneOutstandingUpload() -> Int {
        stateQueue.sync {
            outstandingUploadCount = max(0, outstandingUploadCount - 1)
            return outstandingUploadCount
        }
    }

    private func outstandingUploadCountValue() -> Int {
        stateQueue.sync {
            outstandingUploadCount
        }
    }

    private func resetInvitations() {
        stateQueue.sync {
            invitedPeerIDs.removeAll()
        }
    }

    private func beginBrowsing() {
        browser.stopBrowsingForPeers()
        browser.startBrowsingForPeers()
    }

    private func stopBrowsing() {
        browser.stopBrowsingForPeers()
    }

    private func rebuildTransportStack(disconnectCurrentSession: Bool) {
        cancelScheduledRecovery()
        let oldBrowser = browser
        let oldSession = session

        oldBrowser.stopBrowsingForPeers()
        oldBrowser.delegate = nil

        if disconnectCurrentSession {
            oldSession.disconnect()
        }
        oldSession.delegate = nil

        resetTransientState(preservingCachedFrames: true)

        stateQueue.sync {
            currentSessionState = .notConnected
        }

        let newSession = Self.makeSession(for: peerID)
        let newBrowser = Self.makeBrowser(for: peerID)
        newSession.delegate = self
        newBrowser.delegate = self
        session = newSession
        browser = newBrowser
    }

    private func cancelScheduledRecovery() {
        stateQueue.sync {
            recoveryWorkItem?.cancel()
            recoveryWorkItem = nil
        }
    }

    private func noteSuccessfulConnection() {
        stateQueue.sync {
            lastConnectedAt = Date()
            recoveryWorkItem?.cancel()
            recoveryWorkItem = nil
        }
    }

    private func recoveryDelayLocked(now: Date) -> TimeInterval {
        guard let lastConnectedAt else {
            return 0.8
        }

        let elapsedSinceLastConnection = now.timeIntervalSince(lastConnectedAt)
        if elapsedSinceLastConnection < 3 {
            return 1.8
        }

        if elapsedSinceLastConnection < 10 {
            return 1.2
        }

        return 0.8
    }

    private func scheduleRecovery(afterDisconnecting session: MCSession) {
        let recoveryWorkItem = stateQueue.sync { () -> DispatchWorkItem? in
            guard isStarted else { return nil }

            self.recoveryWorkItem?.cancel()

            let delay = self.recoveryDelayLocked(now: Date())
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                guard session === self.session else { return }

                let shouldRecover = self.stateQueue.sync {
                    self.isStarted && self.currentSessionState == .notConnected
                }
                guard shouldRecover else { return }

                self.rebuildTransportStack(disconnectCurrentSession: false)
                self.beginBrowsing()
                self.updatePublishedState {
                    $0.connectionStatus = "Reconnecting to your Mac…"
                }
            }

            self.recoveryWorkItem = workItem
            self.workQueue.asyncAfter(deadline: .now() + delay, execute: workItem)
            return workItem
        }

        guard recoveryWorkItem != nil else { return }
    }

    private func updateSessionState(_ state: MCSessionState) {
        stateQueue.sync {
            currentSessionState = state
        }
    }

    private func setCurrentSelectionScope(_ scope: ImageSelectionScope) {
        stateQueue.sync {
            activeSelectionScopeState = scope
        }
    }

    private func currentSelectionScope() -> ImageSelectionScope {
        stateQueue.sync {
            activeSelectionScopeState
        }
    }

    private func discardPrefetchedFramesIfScopeDiffers(from scope: ImageSelectionScope) -> [URL] {
        stateQueue.sync {
            guard prefetchedFrames.contains(where: { $0.scope != scope }) else {
                return []
            }

            let removedURLs = prefetchedFrames
                .filter { $0.scope != scope }
                .map(\.fileURL)
            prefetchedFrames.removeAll { $0.scope != scope }
            return removedURLs
        }
    }

    private func synchronizeCurrentFrameStateIfNeeded() {
        guard let currentImageURL,
              let currentFilename,
              let currentAssetID,
              let currentMediaType else {
            return
        }

        stateQueue.sync {
            guard currentFrameState == nil else { return }
            currentFrameState = ViewerFrame(
                assetID: currentAssetID,
                mediaType: currentMediaType,
                image: currentImage,
                fileURL: currentImageURL,
                filename: currentFilename,
                byteSize: estimatedResourceByteSize(at: currentImageURL),
                estimatedMemoryCost: estimatedMemoryCost(for: currentImage),
                isFavorite: currentImageIsFavorite,
                scope: activeSelectionScopeState
            )
        }
    }

    private func takePreviousFrame(matching scope: ImageSelectionScope) -> ViewerFrame? {
        stateQueue.sync {
            guard let matchingIndex = previousFrames.indices.last(where: { previousFrames[$0].scope == scope }) else {
                return nil
            }
            return previousFrames.remove(at: matchingIndex)
        }
    }

    private func takeForwardFrame(matching scope: ImageSelectionScope) -> ViewerFrame? {
        stateQueue.sync {
            guard let matchingIndex = forwardFrames.indices.last(where: { forwardFrames[$0].scope == scope }) else {
                return nil
            }
            return forwardFrames.remove(at: matchingIndex)
        }
    }

    private func discardNavigationHistory() -> [URL] {
        stateQueue.sync {
            let removedURLs = previousFrames.map(\.fileURL) + forwardFrames.map(\.fileURL)
            previousFrames.removeAll()
            forwardFrames.removeAll()
            return removedURLs
        }
    }

    private func clearCurrentFrameState() -> URL? {
        stateQueue.sync {
            let removedURL = currentFrameState?.fileURL
            currentFrameState = nil
            return removedURL
        }
    }

    private func setCurrentFrameScope(_ scope: ImageSelectionScope) {
        stateQueue.sync {
            guard let currentFrameState else { return }
            self.currentFrameState = ViewerFrame(
                assetID: currentFrameState.assetID,
                mediaType: currentFrameState.mediaType,
                image: currentFrameState.image,
                fileURL: currentFrameState.fileURL,
                filename: currentFrameState.filename,
                byteSize: currentFrameState.byteSize,
                estimatedMemoryCost: currentFrameState.estimatedMemoryCost,
                isFavorite: currentFrameState.isFavorite,
                scope: scope
            )
        }
    }

    private func activateFrameInState(_ frame: ViewerFrame, source: FrameActivationSource) -> FrameActivationResult {
        stateQueue.sync {
            var staleURLs: [URL] = []

            switch source {
            case .freshContent:
                if let currentFrameState {
                    previousFrames.append(currentFrameState)
                }
                staleURLs.append(contentsOf: forwardFrames.map(\.fileURL))
                forwardFrames.removeAll()
            case .forwardHistory:
                if let currentFrameState {
                    previousFrames.append(currentFrameState)
                }
            case .backwardHistory:
                if let currentFrameState {
                    forwardFrames.append(currentFrameState)
                }
            }

            trimHistoryFrames(&previousFrames, removedURLs: &staleURLs)
            trimHistoryFrames(&forwardFrames, removedURLs: &staleURLs)

            currentFrameState = frame
            return FrameActivationResult(
                snapshot: navigationPresentationSnapshotLocked(),
                staleURLs: staleURLs
            )
        }
    }

    private func updateFrame(_ frame: ViewerFrame, isFavorite: Bool) -> ViewerFrame {
        ViewerFrame(
            assetID: frame.assetID,
            mediaType: frame.mediaType,
            image: frame.image,
            fileURL: frame.fileURL,
            filename: frame.filename,
            byteSize: frame.byteSize,
            estimatedMemoryCost: frame.estimatedMemoryCost,
            isFavorite: isFavorite,
            scope: frame.scope
        )
    }

    private func trimHistoryFrames(_ frames: inout [ViewerFrame], removedURLs: inout [URL]) {
        while frames.count > historyDepth {
            removedURLs.append(frames.removeFirst().fileURL)
        }
    }

    private func navigationPresentationSnapshot() -> NavigationPresentationSnapshot {
        stateQueue.sync {
            navigationPresentationSnapshotLocked()
        }
    }

    private func navigationPresentationSnapshotLocked() -> NavigationPresentationSnapshot {
        let activeScope = activeSelectionScopeState
        let activePrefetchedFrames = prefetchedFrames.filter { $0.scope == activeScope }
        let forwardFrame = forwardFrames.last(where: { $0.scope == activeScope })
        let previousFrame = previousFrames.last(where: { $0.scope == activeScope })

        return NavigationPresentationSnapshot(
            previousFrame: previousFrame,
            nextFrame: forwardFrame ?? activePrefetchedFrames.first,
            queueCount: activePrefetchedFrames.count,
            queueTargetCount: effectivePrefetchTargetDepthLocked(for: activeScope),
            anyPrefetchInFlight: prefetchRequestsInFlight.values.contains(where: { $0 > 0 })
        )
    }

    private func photoQueuePresentationSnapshotLocked() -> PhotoQueuePresentationSnapshot {
        PhotoQueuePresentationSnapshot(
            photoCount: prefetchedFrames.filter { $0.scope == .all }.count,
            photoTargetCount: effectivePrefetchTargetDepthLocked(for: .all),
            favoritePhotoCount: prefetchedFrames.filter { $0.scope == .favorites }.count,
            favoritePhotoTargetCount: effectivePrefetchTargetDepthLocked(for: .favorites)
        )
    }

    private func publishPhotoPrefetchQueueStates() {
        let snapshot = stateQueue.sync {
            photoQueuePresentationSnapshotLocked()
        }

        updatePublishedState {
            $0.photoPrefetchQueueCount = snapshot.photoCount
            $0.photoPrefetchQueueTargetCount = snapshot.photoTargetCount
            $0.favoritePhotoPrefetchQueueCount = snapshot.favoritePhotoCount
            $0.favoritePhotoPrefetchQueueTargetCount = snapshot.favoritePhotoTargetCount
        }
    }

    private func publishNavigationState() {
        let snapshot = stateQueue.sync { () -> (navigation: NavigationPresentationSnapshot, photoQueues: PhotoQueuePresentationSnapshot) in
            (
                navigationPresentationSnapshotLocked(),
                photoQueuePresentationSnapshotLocked()
            )
        }
        updatePublishedState {
            $0.previousImage = snapshot.navigation.previousFrame?.image
            $0.nextImage = snapshot.navigation.nextFrame?.image
            $0.hasPreviousFrame = snapshot.navigation.previousFrame != nil
            $0.hasNextFrame = snapshot.navigation.nextFrame != nil
            $0.isPrefetching = snapshot.navigation.anyPrefetchInFlight
            $0.prefetchQueueCount = snapshot.navigation.queueCount
            $0.prefetchQueueTargetCount = snapshot.navigation.queueTargetCount
            $0.photoPrefetchQueueCount = snapshot.photoQueues.photoCount
            $0.photoPrefetchQueueTargetCount = snapshot.photoQueues.photoTargetCount
            $0.favoritePhotoPrefetchQueueCount = snapshot.photoQueues.favoritePhotoCount
            $0.favoritePhotoPrefetchQueueTargetCount = snapshot.photoQueues.favoritePhotoTargetCount
        }
    }

    private func publishViewerStateSnapshot(
        connectionStatus: String? = nil,
        hostName: String? = nil,
        updateHostName: Bool = false
    ) {
        let snapshot = stateQueue.sync {
            (
                navigation: navigationPresentationSnapshotLocked(),
                photoQueues: photoQueuePresentationSnapshotLocked(),
                frame: currentFrameState,
                activeScope: activeSelectionScopeState
            )
        }

        updatePublishedState {
            $0.activeSelectionScope = snapshot.activeScope
            $0.previousImage = snapshot.navigation.previousFrame?.image
            $0.currentImage = snapshot.frame?.image
            $0.currentImageURL = snapshot.frame?.fileURL
            $0.currentFilename = snapshot.frame?.filename
            $0.currentAssetID = snapshot.frame?.assetID
            $0.currentMediaType = snapshot.frame?.mediaType
            $0.currentImageIsFavorite = snapshot.frame?.isFavorite ?? false
            $0.nextImage = snapshot.navigation.nextFrame?.image
            $0.hasPreviousFrame = snapshot.navigation.previousFrame != nil
            $0.hasNextFrame = snapshot.navigation.nextFrame != nil
            $0.isLoadingImage = false
            $0.isPrefetching = snapshot.navigation.anyPrefetchInFlight
            $0.isUpdatingFavorite = false
            $0.isDeletingImage = false
            $0.prefetchQueueCount = snapshot.navigation.queueCount
            $0.prefetchQueueTargetCount = snapshot.navigation.queueTargetCount
            $0.photoPrefetchQueueCount = snapshot.photoQueues.photoCount
            $0.photoPrefetchQueueTargetCount = snapshot.photoQueues.photoTargetCount
            $0.favoritePhotoPrefetchQueueCount = snapshot.photoQueues.favoritePhotoCount
            $0.favoritePhotoPrefetchQueueTargetCount = snapshot.photoQueues.favoritePhotoTargetCount
            if let connectionStatus {
                $0.connectionStatus = connectionStatus
            }
            if updateHostName {
                $0.hostName = hostName
            }
        }
    }

    private func reconcileStoredFrameFavoriteState(assetID: UUID, isFavorite: Bool) -> AssetRemovalResult {
        stateQueue.sync {
            var staleURLs: [URL] = []
            let activeScope = activeSelectionScopeState
            let shouldRemoveFromFavorites = !isFavorite
            let removedCurrentFrame: ViewerFrame?

            func reconcile(_ frames: inout [ViewerFrame]) {
                frames.removeAll { frame in
                    guard frame.assetID == assetID else { return false }
                    if shouldRemoveFromFavorites && frame.scope.favoritesOnly {
                        staleURLs.append(frame.fileURL)
                        return true
                    }
                    return false
                }

                frames = frames.map { frame in
                    guard frame.assetID == assetID else { return frame }
                    return updateFrame(frame, isFavorite: isFavorite)
                }
            }

            reconcile(&prefetchedFrames)
            reconcile(&previousFrames)
            reconcile(&forwardFrames)

            if let currentFrameState, currentFrameState.assetID == assetID {
                if shouldRemoveFromFavorites && currentFrameState.scope.favoritesOnly && activeScope.favoritesOnly {
                    removedCurrentFrame = currentFrameState
                    self.currentFrameState = nil
                } else {
                    self.currentFrameState = updateFrame(currentFrameState, isFavorite: isFavorite)
                    removedCurrentFrame = nil
                }
            } else {
                removedCurrentFrame = nil
            }

            return AssetRemovalResult(
                removedCurrentFrame: removedCurrentFrame,
                staleURLs: staleURLs,
                snapshot: navigationPresentationSnapshotLocked()
            )
        }
    }

    private func removeStoredAssetState(assetID: UUID) -> AssetRemovalResult {
        stateQueue.sync {
            var staleURLs: [URL] = []
            let removedCurrentFrame: ViewerFrame?

            func strip(_ frames: inout [ViewerFrame]) {
                frames.removeAll { frame in
                    guard frame.assetID == assetID else { return false }
                    staleURLs.append(frame.fileURL)
                    return true
                }
            }

            strip(&prefetchedFrames)
            strip(&previousFrames)
            strip(&forwardFrames)

            if let currentFrameState, currentFrameState.assetID == assetID {
                removedCurrentFrame = currentFrameState
                self.currentFrameState = nil
            } else {
                removedCurrentFrame = nil
            }

            let resourceNames = pendingResources.compactMap { resourceName, pendingTransfer in
                pendingTransfer.descriptor.assetID == assetID ? resourceName : nil
            }
            for resourceName in resourceNames {
                if let pendingTransfer = pendingResources.removeValue(forKey: resourceName) {
                    switch pendingTransfer.purpose {
                    case .displayNow:
                        displayRequestInFlight = false
                    case .prefetch:
                        prefetchRequestsInFlight[pendingTransfer.scope] = max(
                            0,
                            prefetchRequestsInFlight[pendingTransfer.scope, default: 0] - 1
                        )
                    }
                }

                if let receivedURL = receivedResources.removeValue(forKey: resourceName) {
                    staleURLs.append(receivedURL)
                }
            }

            return AssetRemovalResult(
                removedCurrentFrame: removedCurrentFrame,
                staleURLs: staleURLs,
                snapshot: navigationPresentationSnapshotLocked()
            )
        }
    }

    private func promoteHistoryFrame(_ frame: ViewerFrame, source: FrameActivationSource) {
        let activation = activateFrameInState(frame, source: source)
        recordViewedMedia(mediaType: frame.mediaType)

        updatePublishedState {
            $0.previousImage = activation.snapshot.previousFrame?.image
            $0.currentImage = frame.image
            $0.currentImageURL = frame.fileURL
            $0.currentFilename = frame.filename
            $0.currentAssetID = frame.assetID
            $0.currentMediaType = frame.mediaType
            $0.currentImageIsFavorite = frame.isFavorite
            $0.nextImage = activation.snapshot.nextFrame?.image
            $0.hasPreviousFrame = activation.snapshot.previousFrame != nil
            $0.hasNextFrame = activation.snapshot.nextFrame != nil
            $0.isLoadingImage = false
            $0.isPrefetching = activation.snapshot.anyPrefetchInFlight
            $0.prefetchQueueCount = activation.snapshot.queueCount
            $0.prefetchQueueTargetCount = activation.snapshot.queueTargetCount
            $0.errorMessage = nil
        }

        for staleURL in activation.staleURLs where staleURL != frame.fileURL {
            removeCachedMediaIfNeeded(at: staleURL)
        }

        scheduleViewerStatePersistence()
        publishPhotoPrefetchQueueStates()
    }

    private func updateVideoCatalogFavorite(assetID: UUID, isFavorite: Bool) {
        let activeScope = currentSelectionScope()
        updatePublishedState {
            if activeScope.favoritesOnly && isFavorite == false {
                $0.videoCatalogItems.removeAll { $0.assetID == assetID }
                return
            }

            $0.videoCatalogItems = $0.videoCatalogItems.map { item in
                guard item.assetID == assetID else { return item }
                return VideoCatalogItem(
                    assetID: item.assetID,
                    originalFilename: item.originalFilename,
                    byteSize: item.byteSize,
                    durationSeconds: item.durationSeconds,
                    isFavorite: isFavorite,
                    importedAt: item.importedAt,
                    thumbnailURL: item.thumbnailURL
                )
            }
        }
    }

    private func removeVideoCatalogItem(assetID: UUID) {
        updatePublishedState {
            $0.videoCatalogItems.removeAll { $0.assetID == assetID }
        }
    }

    private func handleFavoriteStatusUpdate(assetID: UUID, isFavorite: Bool) {
        let activeScope = currentSelectionScope()
        let removalResult = reconcileStoredFrameFavoriteState(assetID: assetID, isFavorite: isFavorite)
        let shouldAdvanceFavorites = removalResult.removedCurrentFrame != nil

        updatePublishedState {
            if $0.currentAssetID == assetID {
                $0.currentImageIsFavorite = isFavorite
            }
            $0.previousImage = removalResult.snapshot.previousFrame?.image
            $0.nextImage = removalResult.snapshot.nextFrame?.image
            $0.hasPreviousFrame = removalResult.snapshot.previousFrame != nil
            $0.hasNextFrame = removalResult.snapshot.nextFrame != nil
            $0.isPrefetching = removalResult.snapshot.anyPrefetchInFlight
            $0.prefetchQueueCount = removalResult.snapshot.queueCount
            $0.prefetchQueueTargetCount = removalResult.snapshot.queueTargetCount
            $0.isUpdatingFavorite = false
            $0.errorMessage = nil

            if let removedCurrentFrame = removalResult.removedCurrentFrame {
                if $0.currentAssetID == removedCurrentFrame.assetID {
                    $0.currentImage = nil
                    $0.currentImageURL = nil
                    $0.currentFilename = nil
                    $0.currentAssetID = nil
                    $0.currentMediaType = nil
                    $0.currentImageIsFavorite = false
                    $0.hasPreviousFrame = false
                    $0.hasNextFrame = removalResult.snapshot.nextFrame != nil
                    $0.isLoadingImage = false
                }
            }
        }

        for staleURL in removalResult.staleURLs {
            removeCachedMediaIfNeeded(at: staleURL)
        }
        if let removedCurrentFrame = removalResult.removedCurrentFrame {
            removeCachedMediaIfNeeded(at: removedCurrentFrame.fileURL)
        }

        scheduleViewerStatePersistence()
        publishNavigationState()
        if shouldAdvanceFavorites {
            requestNextImage(in: activeScope)
        } else {
            maintainParallelPhotoPrefetchPipelines(prioritizing: activeScope)
        }
    }

    private func handleDeletedAsset(assetID: UUID, libraryCount: Int?) {
        let activeScope = currentSelectionScope()
        let removalResult = removeStoredAssetState(assetID: assetID)
        let removedCurrentFrame = removalResult.removedCurrentFrame
        clearPendingDeleteRequest(matching: assetID)

        updatePublishedState {
            if let libraryCount {
                $0.libraryCount = libraryCount
            }
            $0.previousImage = removalResult.snapshot.previousFrame?.image
            $0.nextImage = removalResult.snapshot.nextFrame?.image
            $0.hasPreviousFrame = removalResult.snapshot.previousFrame != nil
            $0.hasNextFrame = removalResult.snapshot.nextFrame != nil
            $0.isPrefetching = removalResult.snapshot.anyPrefetchInFlight
            $0.prefetchQueueCount = removalResult.snapshot.queueCount
            $0.prefetchQueueTargetCount = removalResult.snapshot.queueTargetCount
            $0.isUpdatingFavorite = false
            $0.isDeletingImage = false
            $0.errorMessage = nil

            if let removedCurrentFrame, $0.currentAssetID == removedCurrentFrame.assetID {
                $0.currentImage = nil
                $0.currentImageURL = nil
                $0.currentFilename = nil
                $0.currentAssetID = nil
                $0.currentMediaType = nil
                $0.currentImageIsFavorite = false
                $0.hasPreviousFrame = false
                $0.hasNextFrame = removalResult.snapshot.nextFrame != nil
                $0.isLoadingImage = false
            }
        }

        for staleURL in removalResult.staleURLs {
            removeCachedMediaIfNeeded(at: staleURL)
        }
        if let removedCurrentFrame {
            removeCachedMediaIfNeeded(at: removedCurrentFrame.fileURL)
            scheduleViewerStatePersistence()
            publishNavigationState()
            requestNextImage(in: activeScope)
        } else {
            scheduleViewerStatePersistence()
            publishNavigationState()
            maintainParallelPhotoPrefetchPipelines(prioritizing: activeScope)
        }
    }

    private func canInvitePeer(named peerIdentifier: String) -> Bool {
        stateQueue.sync {
            guard currentSessionState == .notConnected else { return false }
            guard !invitedPeerIDs.contains(peerIdentifier) else { return false }
            invitedPeerIDs.insert(peerIdentifier)
            return true
        }
    }

    private func markPeerAsInvited(_ peerIdentifier: String) -> Bool {
        stateQueue.sync {
            guard !invitedPeerIDs.contains(peerIdentifier) else { return false }
            invitedPeerIDs.insert(peerIdentifier)
            return true
        }
    }

    private func pendingPurpose(for resourceName: String) -> ImageRequestPurpose? {
        stateQueue.sync {
            pendingResources[resourceName]?.purpose
        }
    }

    private func resetTransientState(preservingCachedFrames: Bool = false) {
        displayDecodeQueue.cancelAllOperations()
        prefetchDecodeQueue.cancelAllOperations()
        let staleURLs = stateQueue.sync { () -> [URL] in
            invitedPeerIDs.removeAll()
            pendingResources.removeAll()
            pendingDeleteAssetID = nil
            pendingDeleteTimeoutToken = nil
            displayRequestInFlight = false
            prefetchRequestsInFlight.removeAll()
            outstandingUploadCount = 0

            var staleURLs = Array(receivedResources.values)
            receivedResources.removeAll()

            guard preservingCachedFrames == false else {
                return staleURLs
            }

            if let currentFrameState {
                staleURLs.append(currentFrameState.fileURL)
            }
            currentFrameState = nil

            staleURLs.append(contentsOf: previousFrames.map(\.fileURL))
            previousFrames.removeAll()

            staleURLs.append(contentsOf: forwardFrames.map(\.fileURL))
            forwardFrames.removeAll()

            staleURLs.append(contentsOf: prefetchedFrames.map(\.fileURL))
            prefetchedFrames.removeAll()

            return staleURLs
        }

        for staleURL in staleURLs {
            removeCachedMediaIfNeeded(at: staleURL)
        }

        if preservingCachedFrames == false {
            scheduleViewerStatePersistence()
        }
    }

    private func restorePersistedStateIfNeeded() {
        let shouldRestore = stateQueue.sync { () -> Bool in
            guard hasRestoredPersistedState == false else {
                return false
            }
            hasRestoredPersistedState = true
            return true
        }
        guard shouldRestore else { return }

        guard FileManager.default.fileExists(atPath: persistedStateURL.path) else {
            return
        }

        do {
            let stateData = try Data(contentsOf: persistedStateURL)
            let persistedState = try JSONDecoder().decode(PersistedViewerState.self, from: stateData)

            let restoredCurrentFrame = try persistedState.currentFrame.flatMap { persistedFrame in
                try restoredViewerFrame(from: persistedFrame)
            }
            let restoredPreviousFrames = try persistedState.previousFrames.compactMap { persistedFrame in
                try restoredViewerFrame(from: persistedFrame)
            }
            let restoredForwardFrames = try persistedState.forwardFrames.compactMap { persistedFrame in
                try restoredViewerFrame(from: persistedFrame)
            }
            let restoredPrefetchedFrames = try persistedState.prefetchedFrames.compactMap { persistedFrame in
                try restoredViewerFrame(from: persistedFrame)
            }

            stateQueue.sync {
                activeSelectionScopeState = persistedState.activeSelectionScope
                currentFrameState = restoredCurrentFrame
                previousFrames = restoredPreviousFrames
                forwardFrames = restoredForwardFrames
                prefetchedFrames = restoredPrefetchedFrames
            }

            persistViewerStateNow()
        } catch {
            updatePublishedState {
                $0.errorMessage = "Failed to restore the client queue: \(error.localizedDescription)"
            }
        }
    }

    private func scheduleViewerStatePersistence() {
        let shouldSchedule = stateQueue.sync { () -> Bool in
            guard viewerStatePersistenceScheduled == false else {
                return false
            }
            viewerStatePersistenceScheduled = true
            return true
        }
        guard shouldSchedule else { return }

        persistenceQueue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.persistViewerStateNow()
        }
    }

    private func persistViewerStateNow() {
        let persistedState = stateQueue.sync { () -> PersistedViewerState in
            viewerStatePersistenceScheduled = false

            return PersistedViewerState(
                version: 1,
                activeSelectionScope: activeSelectionScopeState,
                currentFrame: currentFrameState.flatMap { persistedViewerFrame(from: $0) },
                previousFrames: previousFrames.compactMap { persistedViewerFrame(from: $0) },
                forwardFrames: forwardFrames.compactMap { persistedViewerFrame(from: $0) },
                prefetchedFrames: prefetchedFrames.compactMap { persistedViewerFrame(from: $0) }
            )
        }

        do {
            let encodedState = try JSONEncoder().encode(persistedState)
            try encodedState.write(to: persistedStateURL, options: .atomic)
        } catch {
            updatePublishedState {
                $0.errorMessage = "Failed to persist the client queue: \(error.localizedDescription)"
            }
        }
    }

    private func persistedViewerFrame(from frame: ViewerFrame) -> PersistedViewerFrame? {
        guard let relativeFilePath = relativeCachePath(for: frame.fileURL) else {
            return nil
        }

        return PersistedViewerFrame(
            assetID: frame.assetID,
            mediaType: frame.mediaType,
            relativeFilePath: relativeFilePath,
            filename: frame.filename,
            byteSize: frame.byteSize,
            estimatedMemoryCost: frame.estimatedMemoryCost,
            isFavorite: frame.isFavorite,
            scope: frame.scope
        )
    }

    private func restoredViewerFrame(from persistedFrame: PersistedViewerFrame) throws -> ViewerFrame? {
        let fileURL = cacheDirectory.appending(path: persistedFrame.relativeFilePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let previewImage = decodePreviewImage(at: fileURL, mediaType: persistedFrame.mediaType)
        if persistedFrame.mediaType == .photo, previewImage == nil {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }

        return ViewerFrame(
            assetID: persistedFrame.assetID,
            mediaType: persistedFrame.mediaType,
            image: previewImage,
            fileURL: fileURL,
            filename: persistedFrame.filename,
            byteSize: persistedFrame.byteSize,
            estimatedMemoryCost: previewImage == nil ? persistedFrame.estimatedMemoryCost : estimatedMemoryCost(for: previewImage),
            isFavorite: persistedFrame.isFavorite,
            scope: persistedFrame.scope
        )
    }

    private func relativeCachePath(for fileURL: URL) -> String? {
        guard fileURL.isFileURL else {
            return nil
        }

        let cachePath = cacheDirectory.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        guard filePath.hasPrefix(cachePath + "/") else {
            return nil
        }

        return String(filePath.dropFirst(cachePath.count + 1))
    }

    private static func defaultDisplayName() -> String {
        #if os(iOS)
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: kCFBundleNameKey as String) as? String)
            ?? "Snaplet Viewer"
        #else
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #endif
    }

    private static func storedViewedTodayCounts() -> (photoCount: Int, videoCount: Int, totalCount: Int) {
        let defaults = UserDefaults.standard
        let todayKey = viewedTodayDateKey()
        guard defaults.string(forKey: "SnapletViewedTodayDate") == todayKey else {
            defaults.set(todayKey, forKey: "SnapletViewedTodayDate")
            defaults.set(0, forKey: "SnapletViewedTodayCount")
            defaults.set(0, forKey: "SnapletViewedTodayPhotoCount")
            defaults.set(0, forKey: "SnapletViewedTodayVideoCount")
            return (0, 0, 0)
        }

        let photoCount = defaults.integer(forKey: "SnapletViewedTodayPhotoCount")
        let videoCount = defaults.integer(forKey: "SnapletViewedTodayVideoCount")
        let totalCount = photoCount + videoCount
        defaults.set(totalCount, forKey: "SnapletViewedTodayCount")
        return (photoCount, videoCount, totalCount)
    }

    private static func incrementStoredViewedTodayCount(for mediaType: MediaType) -> (photoCount: Int, videoCount: Int, totalCount: Int) {
        let defaults = UserDefaults.standard
        let todayKey = viewedTodayDateKey()
        if defaults.string(forKey: "SnapletViewedTodayDate") != todayKey {
            defaults.set(todayKey, forKey: "SnapletViewedTodayDate")
            defaults.set(0, forKey: "SnapletViewedTodayPhotoCount")
            defaults.set(0, forKey: "SnapletViewedTodayVideoCount")
            defaults.set(0, forKey: "SnapletViewedTodayCount")
        }

        switch mediaType {
        case .photo:
            defaults.set(defaults.integer(forKey: "SnapletViewedTodayPhotoCount") + 1, forKey: "SnapletViewedTodayPhotoCount")
        case .video:
            defaults.set(defaults.integer(forKey: "SnapletViewedTodayVideoCount") + 1, forKey: "SnapletViewedTodayVideoCount")
        }

        return storedViewedTodayCounts()
    }

    private static func storedTimeSpentTodaySeconds() -> TimeInterval {
        let defaults = UserDefaults.standard
        let todayKey = viewedTodayDateKey()
        guard defaults.string(forKey: "SnapletTimeSpentTodayDate") == todayKey else {
            defaults.set(todayKey, forKey: "SnapletTimeSpentTodayDate")
            defaults.set(0, forKey: "SnapletTimeSpentTodaySeconds")
            return 0
        }
        return defaults.double(forKey: "SnapletTimeSpentTodaySeconds")
    }

    private static func addStoredTimeSpentTodaySeconds(_ seconds: TimeInterval) -> TimeInterval {
        let defaults = UserDefaults.standard
        let todayKey = viewedTodayDateKey()
        let currentSeconds: TimeInterval
        if defaults.string(forKey: "SnapletTimeSpentTodayDate") == todayKey {
            currentSeconds = defaults.double(forKey: "SnapletTimeSpentTodaySeconds")
        } else {
            defaults.set(todayKey, forKey: "SnapletTimeSpentTodayDate")
            currentSeconds = 0
        }

        let nextSeconds = max(currentSeconds + max(seconds, 0), 0)
        defaults.set(nextSeconds, forKey: "SnapletTimeSpentTodaySeconds")
        return nextSeconds
    }

    private static func viewedTodayDateKey() -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }

    private static func makeDebugAutoUploadPayloads() -> [ImageUploadPayload] {
        #if DEBUG && targetEnvironment(simulator)
        let key = "SNAPLET_DEBUG_UPLOAD_PATHS"
        guard let rawValue = ProcessInfo.processInfo.environment[key], !rawValue.isEmpty else {
            return []
        }

        return rawValue
            .split(separator: "|")
            .map(String.init)
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map {
                ImageUploadPayload(
                    filename: $0.lastPathComponent,
                    temporaryFileURL: $0,
                    shouldDeleteTemporaryFileAfterStaging: false
                )
            }
        #else
        []
        #endif
    }

    private func estimatedResourceByteSize(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let fileSize = attributes?[.size] as? NSNumber else {
            return 0
        }
        return fileSize.int64Value
    }

    private func estimatedMemoryCost(for image: SnapletPlatformImage?) -> Int64 {
        guard let image else {
            return defaultPrefetchedFrameMemoryCost
        }

        #if os(iOS)
        if let cgImage = image.cgImage {
            return Int64(cgImage.bytesPerRow * cgImage.height)
        }

        let width = Int64(max(image.size.width * image.scale, 1))
        let height = Int64(max(image.size.height * image.scale, 1))
        return max(width * height * 4, defaultPrefetchedFrameMemoryCost)
        #else
        return defaultPrefetchedFrameMemoryCost
        #endif
    }

    private func decodePreviewImage(at url: URL, mediaType: MediaType) -> SnapletPlatformImage? {
        switch mediaType {
        case .photo:
            decodeImage(at: url)
        case .video:
            decodeVideoPreview(at: url)
        }
    }

    private func decodeImage(at url: URL) -> SnapletPlatformImage? {
        #if os(iOS)
        let sourceOptions = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldAllowFloat: true
        ] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return nil
        }

        let decodeOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: previewImageMaximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldAllowFloat: true
        ] as CFDictionary

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, decodeOptions) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
        #else
        return NSImage(contentsOf: url)
        #endif
    }

    private func decodeVideoPreview(at url: URL) -> SnapletPlatformImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1_600, height: 1_600)

        let preferredTimes = [
            CMTime(seconds: 0.1, preferredTimescale: 600),
            .zero
        ]

        for preferredTime in preferredTimes {
            guard let cgImage = try? generator.copyCGImage(at: preferredTime, actualTime: nil) else {
                continue
            }

            #if os(iOS)
            return UIImage(cgImage: cgImage)
            #elseif os(macOS)
            return NSImage(cgImage: cgImage, size: .zero)
            #endif
        }

        return nil
    }

    private static func makeSession(for peerID: MCPeerID) -> MCSession {
        MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
    }

    private static func makeBrowser(for peerID: MCPeerID) -> MCNearbyServiceBrowser {
        MCNearbyServiceBrowser(peer: peerID, serviceType: SnapletPeerConfiguration.serviceType)
    }

    private func scheduleDeleteTimeout(for assetID: UUID) {
        let timeoutToken = stateQueue.sync { () -> UUID in
            let token = UUID()
            pendingDeleteAssetID = assetID
            pendingDeleteTimeoutToken = token
            return token
        }

        workQueue.asyncAfter(deadline: .now() + deleteRequestTimeout) { [weak self] in
            guard let self else { return }

            let shouldTimeout = self.stateQueue.sync {
                self.pendingDeleteAssetID == assetID && self.pendingDeleteTimeoutToken == timeoutToken
            }
            guard shouldTimeout else { return }

            self.clearPendingDeleteRequest(matching: assetID)
            self.updatePublishedState {
                guard $0.isDeletingImage else { return }
                $0.isDeletingImage = false
                $0.errorMessage = "Delete timed out before the Mac confirmed it. Try again."
            }
        }
    }

    private func clearPendingDeleteRequest(matching assetID: UUID? = nil) {
        stateQueue.sync {
            guard assetID == nil || pendingDeleteAssetID == assetID else { return }
            pendingDeleteAssetID = nil
            pendingDeleteTimeoutToken = nil
        }
    }
}

#if os(iOS)
private extension UIImage.Orientation {
    init(cgImagePropertyOrientation: CGImagePropertyOrientation) {
        switch cgImagePropertyOrientation {
        case .up:
            self = .up
        case .upMirrored:
            self = .upMirrored
        case .down:
            self = .down
        case .downMirrored:
            self = .downMirrored
        case .left:
            self = .left
        case .leftMirrored:
            self = .leftMirrored
        case .right:
            self = .right
        case .rightMirrored:
            self = .rightMirrored
        @unknown default:
            self = .up
        }
    }
}
#endif

extension PeerViewerService: MCNearbyServiceBrowserDelegate {
    public func browser(
        _ browser: MCNearbyServiceBrowser,
        foundPeer peerID: MCPeerID,
        withDiscoveryInfo info: [String: String]?
    ) {
        guard browser === self.browser else {
            return
        }
        let peerIdentifier = peerID.displayName
        guard canInvitePeer(named: peerIdentifier) else {
            return
        }
        stopBrowsing()
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 10)

        updatePublishedState {
            $0.hostName = peerID.displayName
            $0.connectionStatus = "Inviting \(peerID.displayName)…"
        }
    }

    public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        guard browser === self.browser else {
            return
        }
        let hasConnectedPeers = !session.connectedPeers.isEmpty
        updatePublishedState {
            if $0.hostName == peerID.displayName && !hasConnectedPeers {
                $0.hostName = nil
                $0.connectionStatus = "Host lost. Searching again…"
            }
        }
    }

    public func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        guard browser === self.browser else {
            return
        }
        updatePublishedState {
            $0.errorMessage = error.localizedDescription
            $0.connectionStatus = "Discovery failed"
        }
    }
}

extension PeerViewerService: MCSessionDelegate {
    public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        guard session === self.session else {
            return
        }

        updateSessionState(state)

        switch state {
        case .notConnected:
            resetTransientState(preservingCachedFrames: true)
            publishViewerStateSnapshot(connectionStatus: "Searching for your Mac…", hostName: nil, updateHostName: true)
        case .connecting:
            stopBrowsing()
            updatePublishedState {
                $0.hostName = peerID.displayName
                $0.connectionStatus = "Connecting to \(peerID.displayName)…"
            }
        case .connected:
            stopBrowsing()
            updatePublishedState {
                $0.hostName = peerID.displayName
                $0.connectionStatus = "Connected to \(peerID.displayName)"
            }
        @unknown default:
            updatePublishedState {
                $0.connectionStatus = "Unknown session state"
            }
        }

        if state == .notConnected {
            scheduleRecovery(afterDisconnecting: session)
        } else if state == .connecting {
            cancelScheduledRecovery()
        } else if state == .connected {
            noteSuccessfulConnection()
            if scheduleDebugAutoUploadIfNeeded() {
                updatePublishedState {
                    $0.uploadStatusMessage = "Preparing simulator upload validation…"
                }
            } else if currentAssetID == nil && currentSelectionScope().mediaType == .photo {
                requestImage(purpose: .displayNow, scope: currentSelectionScope())
            } else {
                maintainParallelPhotoPrefetchPipelines(prioritizing: currentSelectionScope())
            }
        }
    }

    public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        workQueue.async { [weak self] in
            guard let self else { return }

            do {
                let message = try PeerMessage.decoded(from: data)
                self.handleMessage(message)
            } catch {
                self.updatePublishedState {
                    $0.errorMessage = error.localizedDescription
                    $0.connectionStatus = "Message decoding failed"
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
        let pendingPurpose = pendingPurpose(for: resourceName)

        updatePublishedState {
            if pendingPurpose != .prefetch {
                $0.isLoadingImage = true
                $0.connectionStatus = "Receiving media from \(peerID.displayName)…"
            } else {
                $0.isPrefetching = true
            }
        }
    }

    public func session(
        _ session: MCSession,
        didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        at localURL: URL?,
        withError error: Error?
    ) {
        completeResourceTransfer(resourceName: resourceName, localURL: localURL, error: error)
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
