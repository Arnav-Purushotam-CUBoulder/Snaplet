import Combine
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
    let image: SnapletPlatformImage
    let fileURL: URL
    let filename: String
    let isFavorite: Bool
    let scope: ImageSelectionScope
}

private typealias PendingTransfer = (descriptor: ResourceDescriptor, purpose: ImageRequestPurpose, scope: ImageSelectionScope)

public final class PeerViewerService: NSObject, ObservableObject, @unchecked Sendable {
    private struct PrefetchPresentationSnapshot {
        let nextFrame: ViewerFrame?
        let queueCount: Int
        let anyPrefetchInFlight: Bool
    }

    @Published public private(set) var connectionStatus = "Searching for your Mac…"
    @Published public private(set) var hostName: String?
    @Published public private(set) var libraryCount = 0
    @Published public private(set) var currentImageURL: URL?
    @Published public private(set) var currentFilename: String?
    @Published public private(set) var currentImage: SnapletPlatformImage?
    @Published public private(set) var currentAssetID: UUID?
    @Published public private(set) var currentImageIsFavorite = false
    @Published public private(set) var nextImage: SnapletPlatformImage?
    @Published public private(set) var prefetchedImageCount = 0
    @Published public private(set) var isLoadingImage = false
    @Published public private(set) var isPrefetching = false
    @Published public private(set) var isUploadingImages = false
    @Published public private(set) var isUpdatingFavorite = false
    @Published public private(set) var activeSelectionScope: ImageSelectionScope = .all
    @Published public private(set) var uploadStatusMessage: String?
    @Published public private(set) var errorMessage: String?

    private let cacheDirectory: URL
    private let uploadStagingDirectory: URL
    private let displayScale: CGFloat
    private let peerID: MCPeerID
    private var session: MCSession
    private var browser: MCNearbyServiceBrowser
    private let stateQueue = DispatchQueue(label: "snaplet.viewer.state")
    private let workQueue = DispatchQueue(label: "snaplet.viewer.service", qos: .userInteractive, attributes: .concurrent)
    private let debugAutoUploadPayloads: [ImageUploadPayload]
    private let prefetchTargetDepth = 5
    private let maxConcurrentPrefetchRequests = 3
    private var invitedPeerIDs: Set<String> = []
    private var pendingResources: [String: PendingTransfer] = [:]
    private var receivedResources: [String: URL] = [:]
    private var prefetchedFrames: [ViewerFrame] = []
    private var outstandingUploadCount = 0
    private var displayRequestInFlight = false
    private var prefetchRequestsInFlight: [ImageSelectionScope: Int] = [:]
    private var hasScheduledDebugAutoUpload = false
    private var isStarted = false
    private var currentSessionState: MCSessionState = .notConnected
    private var activeSelectionScopeState: ImageSelectionScope = .all

    public init(cacheDirectory: URL, displayName: String? = nil, displayScale: CGFloat = 1) {
        self.cacheDirectory = cacheDirectory
        self.uploadStagingDirectory = cacheDirectory.appending(path: "Uploads", directoryHint: .isDirectory)
        self.displayScale = max(displayScale, 1)
        self.peerID = MCPeerID(displayName: displayName ?? Self.defaultDisplayName())
        self.session = Self.makeSession(for: peerID)
        self.browser = Self.makeBrowser(for: peerID)
        self.debugAutoUploadPayloads = Self.makeDebugAutoUploadPayloads()

        super.init()

        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: uploadStagingDirectory, withIntermediateDirectories: true)

        session.delegate = self
        browser.delegate = self
    }

    public func start() {
        stateQueue.sync {
            isStarted = true
        }
        beginBrowsing()
        updatePublishedState {
            $0.connectionStatus = "Searching for your Mac…"
        }
    }

    public func stop() {
        stateQueue.sync {
            isStarted = false
            currentSessionState = .notConnected
        }
        browser.stopBrowsingForPeers()
        session.disconnect()
        resetTransientState()
        updatePublishedState {
            $0.connectionStatus = "Stopped"
            $0.hostName = nil
            $0.isLoadingImage = false
            $0.isPrefetching = false
            $0.isUpdatingFavorite = false
        }
    }

    public func requestNextImage(in scope: ImageSelectionScope? = nil) {
        let targetScope = scope ?? currentSelectionScope()

        guard !session.connectedPeers.isEmpty else {
            updatePublishedState {
                $0.errorMessage = "The Mac host is not connected yet."
                $0.connectionStatus = "Still searching for your Mac…"
            }
            return
        }

        if let prefetchedFrame = takePrefetchedFrame(matching: targetScope) {
            promotePrefetchedFrame(prefetchedFrame)
            maintainPrefetchPipeline(for: targetScope)
            return
        }

        requestImage(purpose: .displayNow, scope: targetScope)
    }

    public func setSelectionScope(_ scope: ImageSelectionScope) {
        let previousScope = currentSelectionScope()
        let canReuseCurrentImage = scope == .all || currentImageIsFavorite
        let hadCurrentImage = currentImage != nil
        let removedPrefetchedURLs = discardPrefetchedFramesIfScopeDiffers(from: scope)
        let removedCurrentURL = hadCurrentImage && !canReuseCurrentImage ? currentImageURL : nil

        setCurrentSelectionScope(scope)
        resetDisplayRequestFlag()
        publishPrefetchState()

        updatePublishedState {
            $0.activeSelectionScope = scope
            $0.errorMessage = nil
            $0.isUpdatingFavorite = false
            $0.nextImage = nil
            $0.prefetchedImageCount = 0

            if hadCurrentImage && !canReuseCurrentImage {
                $0.currentImage = nil
                $0.currentImageURL = nil
                $0.currentFilename = nil
                $0.currentAssetID = nil
                $0.currentImageIsFavorite = false
                $0.isLoadingImage = false
            }
        }

        for removedPrefetchedURL in removedPrefetchedURLs {
            try? FileManager.default.removeItem(at: removedPrefetchedURL)
        }
        if let removedCurrentURL {
            try? FileManager.default.removeItem(at: removedCurrentURL)
        }

        let shouldLoadImmediately = previousScope != scope
            ? (!hadCurrentImage || !canReuseCurrentImage)
            : currentImage == nil && !isLoadingImage

        if shouldLoadImmediately {
            requestNextImage(in: scope)
        } else {
            maintainPrefetchPipeline(for: scope)
        }
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

    public func restartDiscovery() {
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
                $0.errorMessage = "Connect to the Mac host before uploading images."
                $0.uploadStatusMessage = nil
            }
            return
        }

        addOutstandingUploads(payloads.count)
        updatePublishedState {
            $0.isUploadingImages = true
            $0.uploadStatusMessage = "Uploading \(payloads.count) image\((payloads.count == 1) ? "" : "s") to your Mac…"
            $0.errorMessage = nil
        }

        for payload in payloads {
            workQueue.async { [weak self] in
                self?.stageAndUpload(payload, to: hostPeer)
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
                    $0.connectionStatus = "Requesting a random image…"
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
            publishPrefetchState()
        }
    }

    private func maintainPrefetchPipeline(for scope: ImageSelectionScope? = nil) {
        let targetScope = scope ?? currentSelectionScope()
        guard !session.connectedPeers.isEmpty else { return }
        let requestBatchSize = nextPrefetchRequestBatchSize(for: targetScope)
        guard requestBatchSize > 0 else { return }

        for _ in 0..<requestBatchSize {
            requestImage(purpose: .prefetch, scope: targetScope)
        }
    }

    private func promotePrefetchedFrame(_ frame: ViewerFrame) {
        let previousImageURL = currentImageURL
        let hostName = self.hostName
        let prefetchSnapshot = prefetchPresentationSnapshot()

        updatePublishedState {
            $0.currentImage = frame.image
            $0.currentImageURL = frame.fileURL
            $0.currentFilename = frame.filename
            $0.currentAssetID = frame.assetID
            $0.currentImageIsFavorite = frame.isFavorite
            $0.nextImage = prefetchSnapshot.nextFrame?.image
            $0.prefetchedImageCount = prefetchSnapshot.queueCount
            $0.isLoadingImage = false
            $0.errorMessage = nil
            $0.isPrefetching = prefetchSnapshot.anyPrefetchInFlight
            $0.connectionStatus = hostName.map { "Connected to \($0)" } ?? "Connected"
        }

        if let previousImageURL, previousImageURL != frame.fileURL {
            try? FileManager.default.removeItem(at: previousImageURL)
        }
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
            updatePublishedState {
                $0.libraryCount = message.libraryCount ?? 0
            }
        case .transferReady:
            guard let resource = message.resource else { return }

            let purpose = message.requestPurpose ?? .displayNow
            let scope = message.selectionScope ?? .all
            let activeScope = currentSelectionScope()
            let readyURL = registerTransferDescriptor(resource, purpose: purpose, scope: scope)

            if scope == activeScope {
                updatePublishedState {
                    if purpose == .displayNow {
                        $0.currentFilename = resource.originalFilename
                        $0.isLoadingImage = true
                        $0.connectionStatus = readyURL == nil
                            ? "Downloading \(resource.originalFilename)…"
                            : "Preparing \(resource.originalFilename)…"
                    } else {
                        $0.isPrefetching = true
                    }
                }
            }

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
                && currentImage == nil

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
        case .favoriteStatusUpdated:
            guard let assetID = message.assetID, let favoriteValue = message.favoriteValue else { return }
            handleFavoriteStatusUpdate(assetID: assetID, isFavorite: favoriteValue)
        case .failure:
            resetDisplayRequestFlag()
            clearAllPrefetchRequestFlags()
            updatePublishedState {
                $0.isLoadingImage = false
                $0.isUpdatingFavorite = false
                $0.errorMessage = message.errorMessage
                $0.connectionStatus = "Request failed"
            }
            publishPrefetchState()
        case .requestRandomImage, .setFavorite:
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
            publishPrefetchState()
            return
        }

        guard let localURL else {
            clearRequestFlagsForResource(named: resourceName)
            updatePublishedState {
                $0.isLoadingImage = false
                $0.errorMessage = "The host finished a transfer without a file URL."
                $0.connectionStatus = "Transfer failed"
            }
            publishPrefetchState()
            return
        }

        do {
            let destinationURL = cacheDirectory.appending(path: resourceName)
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: localURL, to: destinationURL)

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
            publishPrefetchState()
        }
    }

    private func processReceivedResource(at fileURL: URL, pendingTransfer: PendingTransfer) {
        workQueue.async { [weak self] in
            guard let self else { return }

            guard let decodedImage = self.decodeImage(at: fileURL) else {
                self.clearRequestFlag(for: pendingTransfer.purpose, scope: pendingTransfer.scope)
                self.updatePublishedState {
                    $0.isLoadingImage = false
                    $0.errorMessage = "Failed to decode \(pendingTransfer.descriptor.originalFilename)."
                    $0.connectionStatus = "Decode failed"
                }
                self.publishPrefetchState()
                return
            }

            let frame = ViewerFrame(
                assetID: pendingTransfer.descriptor.assetID,
                image: decodedImage,
                fileURL: fileURL,
                filename: pendingTransfer.descriptor.originalFilename,
                isFavorite: pendingTransfer.descriptor.isFavorite,
                scope: pendingTransfer.scope
            )

            let activeScope = self.currentSelectionScope()
            guard frame.scope == activeScope else {
                self.clearRequestFlag(for: pendingTransfer.purpose, scope: pendingTransfer.scope)
                self.publishPrefetchState()
                try? FileManager.default.removeItem(at: fileURL)
                return
            }

            switch pendingTransfer.purpose {
            case .displayNow:
                self.promoteDecodedFrame(frame)
                self.maintainPrefetchPipeline(for: frame.scope)
            case .prefetch:
                self.storePrefetchedFrame(frame)
            }
        }
    }

    private func promoteDecodedFrame(_ frame: ViewerFrame) {
        let previousImageURL = currentImageURL
        let hostName = self.hostName
        clearRequestFlag(for: .displayNow, scope: frame.scope)
        let prefetchSnapshot = prefetchPresentationSnapshot()

        updatePublishedState {
            $0.currentImage = frame.image
            $0.currentImageURL = frame.fileURL
            $0.currentFilename = frame.filename
            $0.currentAssetID = frame.assetID
            $0.currentImageIsFavorite = frame.isFavorite
            $0.nextImage = prefetchSnapshot.nextFrame?.image
            $0.prefetchedImageCount = prefetchSnapshot.queueCount
            $0.isLoadingImage = false
            $0.isPrefetching = prefetchSnapshot.anyPrefetchInFlight
            $0.errorMessage = nil
            $0.connectionStatus = hostName.map { "Connected to \($0)" } ?? "Connected"
        }

        if let previousImageURL, previousImageURL != frame.fileURL {
            try? FileManager.default.removeItem(at: previousImageURL)
        }
    }

    private func storePrefetchedFrame(_ frame: ViewerFrame) {
        let removedPrefetchedURLs = storePrefetchedFrameInState(frame)
        let prefetchSnapshot = prefetchPresentationSnapshot()

        updatePublishedState {
            $0.nextImage = prefetchSnapshot.nextFrame?.image
            $0.prefetchedImageCount = prefetchSnapshot.queueCount
            $0.isPrefetching = prefetchSnapshot.anyPrefetchInFlight
            if !$0.isLoadingImage {
                $0.connectionStatus = $0.hostName.map { "Connected to \($0)" } ?? "Connected"
            }
        }

        for previousPrefetchedURL in removedPrefetchedURLs where previousPrefetchedURL != frame.fileURL {
            try? FileManager.default.removeItem(at: previousPrefetchedURL)
        }

        maintainPrefetchPipeline(for: frame.scope)
    }

    private func updatePublishedState(_ update: @Sendable @escaping (PeerViewerService) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            update(self)
        }
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
                guard queuedPrefetches + inFlightPrefetches < prefetchTargetDepth else { return false }
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
                try? FileManager.default.removeItem(at: receivedURL)
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
            return max(prefetchTargetDepth - (queuedCount + inFlightCount), 0)
        }
    }

    private func nextPrefetchRequestBatchSize(for scope: ImageSelectionScope) -> Int {
        stateQueue.sync {
            let queuedCount = prefetchedFrames.filter { $0.scope == scope }.count
            let inFlightCount = prefetchRequestsInFlight[scope, default: 0]
            let deficit = max(prefetchTargetDepth - (queuedCount + inFlightCount), 0)
            let availableConcurrency = max(maxConcurrentPrefetchRequests - inFlightCount, 0)
            return min(deficit, availableConcurrency)
        }
    }

    private func storePrefetchedFrameInState(_ frame: ViewerFrame) -> [URL] {
        stateQueue.sync {
            prefetchRequestsInFlight[frame.scope] = max(0, prefetchRequestsInFlight[frame.scope, default: 0] - 1)

            prefetchedFrames.append(frame)

            var removedURLs: [URL] = []
            while prefetchedFrames.filter({ $0.scope == frame.scope }).count > prefetchTargetDepth {
                guard let removalIndex = prefetchedFrames.indices.last(where: { prefetchedFrames[$0].scope == frame.scope }) else {
                    break
                }
                removedURLs.append(prefetchedFrames.remove(at: removalIndex).fileURL)
            }

            return removedURLs
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
        let oldBrowser = browser
        let oldSession = session

        oldBrowser.stopBrowsingForPeers()
        oldBrowser.delegate = nil

        if disconnectCurrentSession {
            oldSession.disconnect()
        }
        oldSession.delegate = nil

        resetTransientState()

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

    private func scheduleRecovery(afterDisconnecting session: MCSession) {
        let shouldRecover = stateQueue.sync {
            isStarted
        }
        guard shouldRecover else { return }

        workQueue.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            guard session === self.session else { return }
            self.rebuildTransportStack(disconnectCurrentSession: false)
            self.beginBrowsing()
        }
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

    private func reconcilePrefetchedFavoriteState(assetID: UUID, isFavorite: Bool) -> [URL] {
        stateQueue.sync {
            var removedURLs: [URL] = []

            prefetchedFrames.removeAll { frame in
                guard frame.assetID == assetID else { return false }
                if frame.scope == .favorites && !isFavorite {
                    removedURLs.append(frame.fileURL)
                    return true
                }
                return false
            }

            prefetchedFrames = prefetchedFrames.map { frame in
                guard frame.assetID == assetID else { return frame }
                return ViewerFrame(
                    assetID: frame.assetID,
                    image: frame.image,
                    fileURL: frame.fileURL,
                    filename: frame.filename,
                    isFavorite: isFavorite,
                    scope: frame.scope
                )
            }

            return removedURLs
        }
    }

    private func handleFavoriteStatusUpdate(assetID: UUID, isFavorite: Bool) {
        let activeScope = currentSelectionScope()
        let removedPrefetchedURLs = reconcilePrefetchedFavoriteState(assetID: assetID, isFavorite: isFavorite)
        let shouldAdvanceFavorites = currentAssetID == assetID && activeScope == .favorites && !isFavorite
        let removedCurrentURL = shouldAdvanceFavorites ? currentImageURL : nil

        updatePublishedState {
            if $0.currentAssetID == assetID {
                $0.currentImageIsFavorite = isFavorite
            }
            $0.isUpdatingFavorite = false
            $0.errorMessage = nil

            if shouldAdvanceFavorites {
                $0.currentImage = nil
                $0.currentImageURL = nil
                $0.currentFilename = nil
                $0.currentAssetID = nil
                $0.currentImageIsFavorite = false
                $0.isLoadingImage = false
            }
        }

        for removedPrefetchedURL in removedPrefetchedURLs {
            try? FileManager.default.removeItem(at: removedPrefetchedURL)
        }
        if let removedCurrentURL {
            try? FileManager.default.removeItem(at: removedCurrentURL)
        }

        publishPrefetchState()
        if shouldAdvanceFavorites {
            requestNextImage(in: .favorites)
        } else if activeScope == .favorites && !removedPrefetchedURLs.isEmpty {
            maintainPrefetchPipeline(for: .favorites)
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

    private func prefetchPresentationSnapshot() -> PrefetchPresentationSnapshot {
        stateQueue.sync {
            let activeScope = activeSelectionScopeState
            let activeFrames = prefetchedFrames.filter { $0.scope == activeScope }
            return PrefetchPresentationSnapshot(
                nextFrame: activeFrames.first,
                queueCount: activeFrames.count,
                anyPrefetchInFlight: prefetchRequestsInFlight.values.contains(where: { $0 > 0 })
            )
        }
    }

    private func publishPrefetchState() {
        let snapshot = prefetchPresentationSnapshot()
        updatePublishedState {
            $0.nextImage = snapshot.nextFrame?.image
            $0.prefetchedImageCount = snapshot.queueCount
            $0.isPrefetching = snapshot.anyPrefetchInFlight
        }
    }

    private func resetTransientState() {
        stateQueue.sync {
            invitedPeerIDs.removeAll()
            pendingResources.removeAll()
            displayRequestInFlight = false
            prefetchRequestsInFlight.removeAll()
            outstandingUploadCount = 0

            for prefetchedFrame in prefetchedFrames {
                try? FileManager.default.removeItem(at: prefetchedFrame.fileURL)
            }
            prefetchedFrames.removeAll()

            for receivedURL in receivedResources.values {
                try? FileManager.default.removeItem(at: receivedURL)
            }
            receivedResources.removeAll()
        }
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
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldAllowFloat: true
        ] as CFDictionary

        let imageProperties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
        let rawOrientation = imageProperties?[kCGImagePropertyOrientation] as? UInt32 ?? 1
        let cgOrientation = CGImagePropertyOrientation(rawValue: rawOrientation) ?? .up

        guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, decodeOptions) else {
            return nil
        }

        return UIImage(
            cgImage: cgImage,
            scale: displayScale,
            orientation: UIImage.Orientation(cgImagePropertyOrientation: cgOrientation)
        )
        #else
        return NSImage(contentsOf: url)
        #endif
    }

    private static func makeSession(for peerID: MCPeerID) -> MCSession {
        MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
    }

    private static func makeBrowser(for peerID: MCPeerID) -> MCNearbyServiceBrowser {
        MCNearbyServiceBrowser(peer: peerID, serviceType: SnapletPeerConfiguration.serviceType)
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

        updatePublishedState {
            switch state {
            case .notConnected:
                self.resetTransientState()
                if $0.hostName == peerID.displayName {
                    $0.hostName = nil
                }
                $0.isLoadingImage = false
                $0.isPrefetching = false
                $0.isUpdatingFavorite = false
                $0.nextImage = nil
                $0.prefetchedImageCount = 0
                $0.connectionStatus = "Searching for your Mac…"
            case .connecting:
                self.stopBrowsing()
                $0.hostName = peerID.displayName
                $0.connectionStatus = "Connecting to \(peerID.displayName)…"
            case .connected:
                self.stopBrowsing()
                $0.hostName = peerID.displayName
                $0.connectionStatus = "Connected to \(peerID.displayName)"
            @unknown default:
                $0.connectionStatus = "Unknown session state"
            }
        }

        if state == .notConnected {
            scheduleRecovery(afterDisconnecting: session)
        } else if state == .connected {
            if scheduleDebugAutoUploadIfNeeded() {
                updatePublishedState {
                    $0.uploadStatusMessage = "Preparing simulator upload validation…"
                }
            } else if currentImage == nil {
                requestImage(purpose: .displayNow, scope: currentSelectionScope())
            } else {
                maintainPrefetchPipeline(for: currentSelectionScope())
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
                $0.connectionStatus = "Receiving image from \(peerID.displayName)…"
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
