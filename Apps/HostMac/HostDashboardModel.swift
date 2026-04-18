import Foundation

@MainActor
final class HostDashboardModel: ObservableObject {
    @Published private(set) var libraryStatus = LibraryStatus(
        assetCount: 0,
        photoCount: 0,
        videoCount: 0,
        favoritePhotoCount: 0,
        favoriteVideoCount: 0,
        recentAssets: []
    )
    @Published private(set) var metadata = SnapletMetadata()
    @Published private(set) var storageRootDirectory: URL
    @Published private(set) var usingFallbackStorage: Bool
    @Published var errorMessage: String?
    @Published var importFeedback: String?
    @Published private(set) var hostService: PeerHostService?

    private let imageLibraryStore: ImageLibraryStore?
    private let metadataStore: SnapletMetadataStore?

    init(rootDirectory: URL, usingFallbackStorage: Bool) {
        self.storageRootDirectory = rootDirectory
        self.usingFallbackStorage = usingFallbackStorage

        do {
            let store = try ImageLibraryStore(rootDirectory: rootDirectory)
            self.imageLibraryStore = store
            self.metadataStore = SnapletMetadataStore(rootDirectory: rootDirectory)

            let hostService = PeerHostService(imageLibraryStore: store)
            hostService.onLibraryMutated = { [weak self] in
                Task { @MainActor in
                    self?.refreshLibrary()
                }
            }
            self.hostService = hostService
            hostService.start()

            refreshLibrary()
        } catch {
            self.imageLibraryStore = nil
            self.metadataStore = nil
            self.hostService = nil
            self.errorMessage = error.localizedDescription
        }
    }

    init(storageRootDirectory: URL, configurationError: Error) {
        self.storageRootDirectory = storageRootDirectory
        self.usingFallbackStorage = false
        self.errorMessage = configurationError.localizedDescription
        self.imageLibraryStore = nil
        self.metadataStore = nil
        self.hostService = nil
    }

    func refreshLibrary() {
        guard let imageLibraryStore else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            do {
                let status = try imageLibraryStore.libraryStatus()
                let metadata = try self.metadataStore?.load() ?? SnapletMetadata()
                Task { @MainActor in
                    self.libraryStatus = status
                    self.metadata = metadata
                    self.errorMessage = nil
                }
            } catch {
                Task { @MainActor in
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func importAssets(from urls: [URL]) {
        guard let imageLibraryStore else { return }

        let scopedURLs = urls.filter { $0.startAccessingSecurityScopedResource() }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer {
                scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
            }

            guard let self else { return }

            do {
                let importedAssets = try imageLibraryStore.importAssets(from: scopedURLs)
                let status = try imageLibraryStore.libraryStatus()
                let photoCount = importedAssets.filter(\.isPhoto).count
                let videoCount = importedAssets.filter(\.isVideo).count
                let feedback = "Imported \(photoCount) photo\(photoCount == 1 ? "" : "s") and \(videoCount) video\(videoCount == 1 ? "" : "s")."

                Task { @MainActor in
                    self.libraryStatus = status
                    self.importFeedback = feedback
                    self.errorMessage = nil
                }
            } catch {
                Task { @MainActor in
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func reindexLibrary() {
        guard let imageLibraryStore else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            do {
                let summary = try imageLibraryStore.migrateLegacyLibraryAndReindex()
                let status = try imageLibraryStore.libraryStatus()
                let feedback = "Indexed \(summary.reindex.indexedPhotoCount) photos and \(summary.reindex.indexedVideoCount) videos."

                Task { @MainActor in
                    self.libraryStatus = status
                    self.importFeedback = feedback
                    self.errorMessage = nil
                }
            } catch {
                Task { @MainActor in
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }
}
