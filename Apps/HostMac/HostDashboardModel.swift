import Foundation

@MainActor
final class HostDashboardModel: ObservableObject {
    @Published private(set) var libraryStatus = LibraryStatus(imageCount: 0, recentAssets: [])
    @Published private(set) var storageRootDirectory: URL
    @Published private(set) var usingFallbackStorage: Bool
    @Published var errorMessage: String?
    @Published var importFeedback: String?
    @Published private(set) var hostService: PeerHostService?

    private let imageLibraryStore: ImageLibraryStore?

    init(rootDirectory: URL, usingFallbackStorage: Bool) {
        self.storageRootDirectory = rootDirectory
        self.usingFallbackStorage = usingFallbackStorage

        do {
            let store = try ImageLibraryStore(rootDirectory: rootDirectory)
            self.imageLibraryStore = store

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
            self.hostService = nil
            self.errorMessage = error.localizedDescription
        }
    }

    init(storageRootDirectory: URL, configurationError: Error) {
        self.storageRootDirectory = storageRootDirectory
        self.usingFallbackStorage = false
        self.errorMessage = configurationError.localizedDescription
        self.imageLibraryStore = nil
        self.hostService = nil
    }

    func refreshLibrary() {
        guard let imageLibraryStore else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            do {
                let status = try imageLibraryStore.libraryStatus()
                Task { @MainActor in
                    self.libraryStatus = status
                    self.errorMessage = nil
                }
            } catch {
                Task { @MainActor in
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func importImages(from urls: [URL]) {
        guard let imageLibraryStore else { return }

        let scopedURLs = urls.filter { $0.startAccessingSecurityScopedResource() }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer {
                scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
            }

            guard let self else { return }

            do {
                let importedAssets = try imageLibraryStore.importImages(from: scopedURLs)
                let status = try imageLibraryStore.libraryStatus()
                let feedback = "Imported \(importedAssets.count) image\(importedAssets.count == 1 ? "" : "s")."

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
