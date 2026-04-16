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
    let image: SnapletPlatformImage
    let fileURL: URL
    let filename: String
}

private typealias PendingTransfer = (descriptor: ResourceDescriptor, purpose: ImageRequestPurpose)

public final class PeerViewerService: NSObject, ObservableObject, @unchecked Sendable {
    @Published public private(set) var connectionStatus = "Searching for your Mac…"
    @Published public private(set) var hostName: String?
    @Published public private(set) var libraryCount = 0
    @Published public private(set) var currentImageURL: URL?
    @Published public private(set) var currentFilename: String?
    @Published public private(set) var currentImage: SnapletPlatformImage?
    @Published public private(set) var isLoadingImage = false
    @Published public private(set) var isPrefetching = false
    @Published public private(set) var isUploadingImages = false
    @Published public private(set) var uploadStatusMessage: String?
    @Published public private(set) var errorMessage: String?

    private let cacheDirectory: URL
    private let uploadStagingDirectory: URL
    private let peerID: MCPeerID
    private var session: MCSession
    private var browser: MCNearbyServiceBrowser
    private let stateQueue = DispatchQueue(label: "snaplet.viewer.state")
    private let workQueue = DispatchQueue(label: "snaplet.viewer.service", qos: .userInitiated, attributes: .concurrent)
    private let debugAutoUploadPayloads: [ImageUploadPayload]
    private var invitedPeerIDs: Set<String> = []
    private var pendingResources: [String: PendingTransfer] = [:]
    private var receivedResources: [String: URL] = [:]
    private var prefetchedFrame: ViewerFrame?
    private var outstandingUploadCount = 0
    private var displayRequestInFlight = false
    private var prefetchRequestInFlight = false
    private var hasScheduledDebugAutoUpload = false
    private var isStarted = false
    private var currentSessionState: MCSessionState = .notConnected

    public init(cacheDirectory: URL, displayName: String? = nil) {
        self.cacheDirectory = cacheDirectory
        self.uploadStagingDirectory = cacheDirectory.appending(path: "Uploads", directoryHint: .isDirectory)
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
        }
    }

    public func requestNextImage() {
        guard !session.connectedPeers.isEmpty else {
            updatePublishedState {
                $0.errorMessage = "The Mac host is not connected yet."
                $0.connectionStatus = "Still searching for your Mac…"
            }
            return
        }

        if let prefetchedFrame = takePrefetchedFrame() {
            promotePrefetchedFrame(prefetchedFrame)
            requestPrefetchIfPossible()
            return
        }

        requestImage(purpose: .displayNow)
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

    private func requestImage(purpose: ImageRequestPurpose) {
        guard !session.connectedPeers.isEmpty else { return }
        guard reserveRequestSlot(for: purpose) else { return }

        do {
            try session.send(
                PeerMessage.requestRandomImage(purpose: purpose).encoded(),
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
            clearRequestFlag(for: purpose)
            updatePublishedState {
                $0.errorMessage = error.localizedDescription
                $0.connectionStatus = "Request failed"
                $0.isLoadingImage = false
                $0.isPrefetching = false
            }
        }
    }

    private func requestPrefetchIfPossible() {
        guard !session.connectedPeers.isEmpty else { return }
        guard !hasPrefetchedFrame() else { return }
        requestImage(purpose: .prefetch)
    }

    private func promotePrefetchedFrame(_ frame: ViewerFrame) {
        let previousImageURL = currentImageURL
        let hostName = self.hostName

        updatePublishedState {
            $0.currentImage = frame.image
            $0.currentImageURL = frame.fileURL
            $0.currentFilename = frame.filename
            $0.isLoadingImage = false
            $0.errorMessage = nil
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
            let readyURL = registerTransferDescriptor(resource, purpose: purpose)

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

            if let readyURL {
                processReceivedResource(
                    at: readyURL,
                    pendingTransfer: (descriptor: resource, purpose: purpose)
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
        case .failure:
            resetRequestFlags()
            updatePublishedState {
                $0.isLoadingImage = false
                $0.isPrefetching = false
                $0.errorMessage = message.errorMessage
                $0.connectionStatus = "Request failed"
            }
        case .requestRandomImage:
            break
        }
    }

    private func completeResourceTransfer(resourceName: String, localURL: URL?, error: Error?) {
        if let error {
            clearRequestFlagsForResource(named: resourceName)
            updatePublishedState {
                $0.isLoadingImage = false
                $0.isPrefetching = false
                $0.errorMessage = error.localizedDescription
                $0.connectionStatus = "Transfer failed"
            }
            return
        }

        guard let localURL else {
            clearRequestFlagsForResource(named: resourceName)
            updatePublishedState {
                $0.isLoadingImage = false
                $0.isPrefetching = false
                $0.errorMessage = "The host finished a transfer without a file URL."
                $0.connectionStatus = "Transfer failed"
            }
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
                $0.isPrefetching = false
                $0.errorMessage = error.localizedDescription
                $0.connectionStatus = "Transfer failed"
            }
        }
    }

    private func processReceivedResource(at fileURL: URL, pendingTransfer: PendingTransfer) {
        workQueue.async { [weak self] in
            guard let self else { return }

            guard let decodedImage = Self.decodeImage(at: fileURL) else {
                self.clearRequestFlag(for: pendingTransfer.purpose)
                self.updatePublishedState {
                    $0.isLoadingImage = false
                    $0.isPrefetching = false
                    $0.errorMessage = "Failed to decode \(pendingTransfer.descriptor.originalFilename)."
                    $0.connectionStatus = "Decode failed"
                }
                return
            }

            let frame = ViewerFrame(
                image: decodedImage,
                fileURL: fileURL,
                filename: pendingTransfer.descriptor.originalFilename
            )

            switch pendingTransfer.purpose {
            case .displayNow:
                self.promoteDecodedFrame(frame)
                self.requestPrefetchIfPossible()
            case .prefetch:
                self.storePrefetchedFrame(frame)
            }
        }
    }

    private func promoteDecodedFrame(_ frame: ViewerFrame) {
        let previousImageURL = currentImageURL
        let hostName = self.hostName
        clearRequestFlag(for: .displayNow)

        updatePublishedState {
            $0.currentImage = frame.image
            $0.currentImageURL = frame.fileURL
            $0.currentFilename = frame.filename
            $0.isLoadingImage = false
            $0.errorMessage = nil
            $0.connectionStatus = hostName.map { "Connected to \($0)" } ?? "Connected"
        }

        if let previousImageURL, previousImageURL != frame.fileURL {
            try? FileManager.default.removeItem(at: previousImageURL)
        }
    }

    private func storePrefetchedFrame(_ frame: ViewerFrame) {
        let previousPrefetchedURL = storePrefetchedFrameInState(frame)

        updatePublishedState {
            $0.isPrefetching = false
            if !$0.isLoadingImage {
                $0.connectionStatus = $0.hostName.map { "Connected to \($0)" } ?? "Connected"
            }
        }

        if let previousPrefetchedURL, previousPrefetchedURL != frame.fileURL {
            try? FileManager.default.removeItem(at: previousPrefetchedURL)
        }
    }

    private func updatePublishedState(_ update: @Sendable @escaping (PeerViewerService) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            update(self)
        }
    }

    private func reserveRequestSlot(for purpose: ImageRequestPurpose) -> Bool {
        stateQueue.sync {
            switch purpose {
            case .displayNow:
                guard !displayRequestInFlight else { return false }
                displayRequestInFlight = true
                return true
            case .prefetch:
                guard !prefetchRequestInFlight, prefetchedFrame == nil else { return false }
                prefetchRequestInFlight = true
                return true
            }
        }
    }

    private func clearRequestFlag(for purpose: ImageRequestPurpose) {
        stateQueue.sync {
            switch purpose {
            case .displayNow:
                displayRequestInFlight = false
            case .prefetch:
                prefetchRequestInFlight = false
            }
        }
    }

    private func resetRequestFlags() {
        stateQueue.sync {
            displayRequestInFlight = false
            prefetchRequestInFlight = false
        }
    }

    private func registerTransferDescriptor(_ descriptor: ResourceDescriptor, purpose: ImageRequestPurpose) -> URL? {
        stateQueue.sync {
            if let receivedURL = receivedResources.removeValue(forKey: descriptor.resourceName) {
                return receivedURL
            }

            pendingResources[descriptor.resourceName] = (descriptor, purpose)
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
                    prefetchRequestInFlight = false
                }
            }

            if let receivedURL = receivedResources.removeValue(forKey: resourceName) {
                try? FileManager.default.removeItem(at: receivedURL)
            }
        }
    }

    private func takePrefetchedFrame() -> ViewerFrame? {
        stateQueue.sync {
            let frame = prefetchedFrame
            prefetchedFrame = nil
            return frame
        }
    }

    private func hasPrefetchedFrame() -> Bool {
        stateQueue.sync {
            prefetchedFrame != nil
        }
    }

    private func storePrefetchedFrameInState(_ frame: ViewerFrame) -> URL? {
        stateQueue.sync {
            let previousURL = prefetchedFrame?.fileURL
            prefetchedFrame = frame
            prefetchRequestInFlight = false
            return previousURL
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

    private func resetTransientState() {
        stateQueue.sync {
            invitedPeerIDs.removeAll()
            pendingResources.removeAll()
            displayRequestInFlight = false
            prefetchRequestInFlight = false
            outstandingUploadCount = 0

            if let prefetchedFrame {
                try? FileManager.default.removeItem(at: prefetchedFrame.fileURL)
            }
            prefetchedFrame = nil

            for receivedURL in receivedResources.values {
                try? FileManager.default.removeItem(at: receivedURL)
            }
            receivedResources.removeAll()
        }
    }

    private static func defaultDisplayName() -> String {
        #if os(iOS)
        UIDevice.current.name
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

    private static func decodeImage(at url: URL) -> SnapletPlatformImage? {
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

        guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, decodeOptions) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
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
                requestImage(purpose: .displayNow)
            } else {
                requestPrefetchIfPossible()
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
