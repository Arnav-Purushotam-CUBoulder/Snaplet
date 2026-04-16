import Combine
import Foundation
@preconcurrency import MultipeerConnectivity
#if os(iOS)
import UIKit
#endif

public final class PeerHostService: NSObject, ObservableObject, @unchecked Sendable {
    @Published public private(set) var isAdvertising = false
    @Published public private(set) var connectionStatus = "Idle"
    @Published public private(set) var connectedPeerNames: [String] = []
    @Published public private(set) var activityLog: [String] = []
    @Published public private(set) var lastError: String?

    private let imageLibraryStore: ImageLibraryStore
    private let peerID: MCPeerID
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let workQueue = DispatchQueue(label: "snaplet.host.service", qos: .userInitiated, attributes: .concurrent)

    public var onLibraryMutated: (@Sendable () -> Void)?

    public init(imageLibraryStore: ImageLibraryStore, displayName: String? = nil) {
        self.imageLibraryStore = imageLibraryStore
        self.peerID = MCPeerID(displayName: displayName ?? Self.defaultDisplayName())
        self.session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        self.advertiser = MCNearbyServiceAdvertiser(
            peer: peerID,
            discoveryInfo: nil,
            serviceType: SnapletPeerConfiguration.serviceType
        )

        super.init()

        session.delegate = self
        advertiser.delegate = self
    }

    public func start() {
        advertiser.startAdvertisingPeer()
        updatePublishedState {
            $0.isAdvertising = true
            $0.connectionStatus = "Advertising as \($0.peerID.displayName)"
            $0.appendLog("Advertising for iPhone viewers.")
        }
    }

    public func stop() {
        advertiser.stopAdvertisingPeer()
        session.disconnect()
        updatePublishedState {
            $0.isAdvertising = false
            $0.connectedPeerNames = []
            $0.connectionStatus = "Stopped"
            $0.appendLog("Stopped advertising.")
        }
    }

    private func handleRandomImageRequest(from peerID: MCPeerID, purpose: ImageRequestPurpose) {
        do {
            let imageCount = try imageLibraryStore.assetCount()
            try sendMessage(.libraryStatus(count: imageCount), to: [peerID])

            guard let asset = try imageLibraryStore.randomAsset() else {
                try sendMessage(.failure("No images have been imported yet."), to: [peerID])
                updatePublishedState {
                    $0.appendLog("Random image request from \(peerID.displayName) failed because the library is empty.")
                }
                return
            }

            let resourceName = asset.storedFilename
            let descriptor = ResourceDescriptor(
                assetID: asset.id,
                resourceName: resourceName,
                originalFilename: asset.originalFilename,
                byteSize: asset.byteSize
            )

            try sendMessage(.transferReady(descriptor, purpose: purpose), to: [peerID])

            let fileURL = asset.fileURL(relativeTo: imageLibraryStore.rootDirectory)
            session.sendResource(at: fileURL, withName: resourceName, toPeer: peerID) { [weak self] error in
                guard let self else { return }

                if let error {
                    self.updatePublishedState {
                        $0.lastError = error.localizedDescription
                        $0.appendLog("Resource transfer to \(peerID.displayName) failed: \(error.localizedDescription)")
                    }
                    try? self.sendMessage(.failure("Transfer failed: \(error.localizedDescription)"), to: [peerID])
                } else {
                    self.updatePublishedState {
                        $0.appendLog("Sent \(asset.originalFilename) to \(peerID.displayName).")
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

    private func sendMessage(_ message: PeerMessage, to peers: [MCPeerID]) throws {
        let data = try message.encoded()
        try session.send(data, toPeers: peers, with: .reliable)
    }

    private func sendLibraryStatus(to peers: [MCPeerID]) throws {
        try sendMessage(.libraryStatus(count: try imageLibraryStore.assetCount()), to: peers)
    }

    private func handleIncomingUpload(
        named resourceName: String,
        from peerID: MCPeerID,
        localURL: URL?,
        error: Error?
    ) {
        let peerName = peerID.displayName

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

        do {
            let importedAsset = try imageLibraryStore.importReceivedFile(at: localURL, originalFilename: resourceName)
            let libraryCount = try imageLibraryStore.assetCount()
            let descriptor = ResourceDescriptor(
                assetID: importedAsset.id,
                resourceName: importedAsset.storedFilename,
                originalFilename: importedAsset.originalFilename,
                byteSize: importedAsset.byteSize
            )

            try sendMessage(.uploadComplete(descriptor, count: libraryCount), to: [peerID])
            try sendLibraryStatus(to: session.connectedPeers)

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

    private func updatePublishedState(_ update: @Sendable @escaping (PeerHostService) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            update(self)
        }
    }

    private func appendLog(_ message: String) {
        let timestamp = DateFormatter.hostActivityFormatter.string(from: Date())
        activityLog.insert("[\(timestamp)] \(message)", at: 0)
        if activityLog.count > 30 {
            activityLog.removeLast(activityLog.count - 30)
        }
    }

    private static func defaultDisplayName() -> String {
        #if os(iOS)
        UIDevice.current.name
        #else
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #endif
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
        if session.connectedPeers.contains(peerID) || !session.connectedPeers.isEmpty {
            invitationHandler(false, nil)
            updatePublishedState {
                $0.appendLog("Rejected duplicate invitation from \(peerID.displayName).")
            }
            return
        }

        invitationHandler(true, session)
        updatePublishedState {
            $0.appendLog("Accepted invitation from \(peerID.displayName).")
        }
    }
}

extension PeerHostService: MCSessionDelegate {
    public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
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
                if message.kind == .requestRandomImage {
                    self.handleRandomImageRequest(
                        from: peerID,
                        purpose: message.requestPurpose ?? .displayNow
                    )
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
        workQueue.async { [weak self] in
            self?.handleIncomingUpload(
                named: resourceName,
                from: peerID,
                localURL: localURL,
                error: error
            )
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
