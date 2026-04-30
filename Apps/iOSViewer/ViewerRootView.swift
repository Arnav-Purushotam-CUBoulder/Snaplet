import SwiftUI
import AVKit
import CoreTransferable
import PhotosUI
import UniformTypeIdentifiers
import UIKit

private enum ViewerScreenMode: String, CaseIterable, Identifiable {
    case menu = "Menu"
    case photos = "Photos"
    case favoritePhotos = "Favorite Photos"
    case videos = "Videos"
    case videoAlbum = "Video Album"
    case favoriteVideos = "Favorite Videos"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .menu:
            "slider.horizontal.3"
        case .photos:
            "photo.on.rectangle.angled"
        case .favoritePhotos:
            "star.fill"
        case .videos:
            "play.rectangle.fill"
        case .videoAlbum:
            "rectangle.stack.fill.badge.play"
        case .favoriteVideos:
            "star.square.on.square"
        }
    }

    var selectionScope: ImageSelectionScope? {
        switch self {
        case .menu:
            nil
        case .photos:
            .all
        case .favoritePhotos:
            .favorites
        case .videos, .videoAlbum:
            .videos
        case .favoriteVideos:
            .favoriteVideos
        }
    }

    var emptyStateTitle: String {
        switch self {
        case .menu:
            "Menu"
        case .photos:
            "No Photos Yet"
        case .favoritePhotos:
            "No Favorite Photos"
        case .videos:
            "No Videos Yet"
        case .videoAlbum:
            "No Videos Yet"
        case .favoriteVideos:
            "No Favorite Videos"
        }
    }

    var emptyStateMessage: String {
        switch self {
        case .menu:
            ""
        case .photos:
            "Swipe up to pull a random photo from your Mac host."
        case .favoritePhotos:
            "Mark photos with the star in Photos, then switch back here for a favorites-only shuffle."
        case .videos:
            "Swipe up to pull a random video from your Mac host."
        case .videoAlbum:
            "Upload videos from your iPhone or Mac, then sort and select them here."
        case .favoriteVideos:
            "Mark videos with the star in Videos, then switch back here for a favorites-only shuffle."
        }
    }
}

private enum VideoCatalogNavigationDirection {
    case previous
    case next
}

struct ViewerRootView: View {
    @StateObject private var service: PeerViewerService
    @State private var feedDragOffset: CGFloat = 0
    @State private var isAnimatingFeedAdvance = false
    @State private var isInteractingWithVideoControls = false
    @State private var isVideoChromeHidden = false
    @State private var isVideoCatalogPlayerPresented = false
    @State private var videoCatalogSort: VideoCatalogSort = .newest
    @State private var isPresentingThumbnailPicker = false
    @State private var selectedThumbnailPickerItem: PhotosPickerItem?
    @State private var pendingThumbnailAssetID: UUID?
    @State private var selectedUploadItems: [PhotosPickerItem] = []
    @State private var selectedScreen: ViewerScreenMode = .menu
    @State private var isModeSwitcherTemporarilyVisible = false
    @State private var modeSwitcherVisibilityToken = UUID()
    @State private var videoAlbumFavoritesOnly = false
    @State private var isVideoAlbumSelecting = false
    @State private var selectedVideoCatalogAssetIDs: Set<UUID> = []
    @State private var isPresentingAlbumDeleteConfirmation = false
    @State private var viewerZoomScale: CGFloat = 1
    @State private var viewerMinimumZoomScale: CGFloat = 1
    @State private var isPresentingDeleteConfirmation = false
    @State private var photoTransitionCoverImage: UIImage?
    @State private var photoTransitionCoverOpacity = 1.0
    @State private var awaitingPhotoTransitionAssetID: UUID?
    @State private var latestReadyPhotoAssetID: UUID?
    @State private var photoTransitionCoverToken = UUID()
    private let screenTransitionAnimation = Animation.easeInOut(duration: 0.24)
    private let feedSlideAnimation = Animation.timingCurve(0.22, 0.92, 0.28, 1, duration: 0.22)
    private let feedReturnAnimation = Animation.interactiveSpring(response: 0.24, dampingFraction: 0.9, blendDuration: 0.08)
    private let feedNudgeAnimation = Animation.easeOut(duration: 0.12)

    @MainActor
    init() {
        let cacheDirectory = (try? AppSupportPaths.viewerCacheDirectory()) ?? FileManager.default.temporaryDirectory
        _service = StateObject(
            wrappedValue: PeerViewerService(
                cacheDirectory: cacheDirectory,
                displayScale: UIScreen.main.scale
            )
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let topInset = proxy.safeAreaInsets.top

            ZStack(alignment: .top) {
                backgroundSurface

                Group {
                    if selectedScreen == .menu {
                        menuScreen(topInset: topInset)
                            .transition(.opacity.combined(with: .move(edge: .leading)))
                    } else {
                        viewerScreen(for: selectedScreen, topInset: topInset)
                            .transition(.opacity.combined(with: .move(edge: .trailing)))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

                if shouldShowModeSwitcher {
                    ViewerModeSwitcher(selectedMode: $selectedScreen)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 18)
                        .padding(.top, max(topInset - 8, 0))
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .simultaneousGesture(horizontalTabSwipeGesture)
        }
        .onAppear {
            service.start()
            service.setFeedPrefetchingEnabled(true)
        }
        .onDisappear {
            service.stop()
        }
        .onChange(of: selectedScreen) { _, screen in
            let resetTransaction = Transaction(animation: nil)
            withTransaction(resetTransaction) {
                feedDragOffset = 0
                isAnimatingFeedAdvance = false
                isInteractingWithVideoControls = false
                isVideoChromeHidden = false
                isVideoCatalogPlayerPresented = false
                isVideoAlbumSelecting = false
                selectedVideoCatalogAssetIDs = []
            }
            clearPhotoTransitionCover()
            guard let scope = screen.selectionScope else {
                return
            }
            service.setSelectionScope(scope)
            service.setFeedPrefetchingEnabled(true)
            switch screen {
            case .videoAlbum:
                service.requestVideoCatalog(scope: videoAlbumScope, sort: videoCatalogSort)
            case .videos, .favoriteVideos:
                service.requestNextImage(in: scope)
            case .menu, .photos, .favoritePhotos:
                break
            }
        }
        .onChange(of: selectedUploadItems) { _, items in
            guard !items.isEmpty else { return }

            Task {
                await prepareUploads(from: items)
                await MainActor.run {
                    selectedUploadItems = []
                }
            }
        }
        .onChange(of: videoCatalogSort) { _, sort in
            guard selectedScreen == .videoAlbum else { return }
            service.requestVideoCatalog(scope: videoAlbumScope, sort: sort)
        }
        .onChange(of: videoAlbumFavoritesOnly) { _, _ in
            guard selectedScreen == .videoAlbum else { return }
            selectedVideoCatalogAssetIDs = []
            service.requestVideoCatalog(scope: videoAlbumScope, sort: videoCatalogSort)
        }
        .onChange(of: selectedThumbnailPickerItem) { _, item in
            guard let item else { return }

            Task {
                await prepareVideoThumbnail(from: item)
                await MainActor.run {
                    selectedThumbnailPickerItem = nil
                }
            }
        }
        .photosPicker(
            isPresented: $isPresentingThumbnailPicker,
            selection: $selectedThumbnailPickerItem,
            matching: .images,
            preferredItemEncoding: .current,
            photoLibrary: .shared()
        )
        .confirmationDialog(
            "Delete this media item from the Mac library?",
            isPresented: $isPresentingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Item", role: .destructive) {
                service.deleteCurrentImage()
            }
        } message: {
            Text("This removes the item from the Mac host and deletes the underlying file as well.")
        }
        .confirmationDialog(
            "Delete selected videos from the Mac library?",
            isPresented: $isPresentingAlbumDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete \(selectedVideoCatalogAssetIDs.count) Video\(selectedVideoCatalogAssetIDs.count == 1 ? "" : "s")", role: .destructive) {
                deleteSelectedCatalogVideos()
            }
        } message: {
            Text("This removes the selected videos from the Mac host and deletes the underlying files as well.")
        }
    }

    private var backgroundSurface: some View {
        Group {
            switch selectedScreen {
            case .menu:
                LinearGradient(
                    colors: [
                        Color(red: 0.06, green: 0.08, blue: 0.12),
                        Color(red: 0.18, green: 0.12, blue: 0.10),
                        Color(red: 0.44, green: 0.22, blue: 0.10)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            case .photos, .favoritePhotos, .videos, .videoAlbum, .favoriteVideos:
                Color.black
            }
        }
        .ignoresSafeArea()
    }

    private var shouldShowModeSwitcher: Bool {
        guard selectedScreen != .menu else {
            return true
        }
        guard selectedScreen.selectionScope?.mediaType == .video else {
            return isModeSwitcherTemporarilyVisible
        }
        return !isVideoChromeHidden && isModeSwitcherTemporarilyVisible
    }

    private var videoAlbumScope: ImageSelectionScope {
        videoAlbumFavoritesOnly ? .favoriteVideos : .videos
    }

    private var horizontalTabSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 28, coordinateSpace: .global)
            .onEnded { value in
                handleHorizontalTabSwipe(value)
            }
    }

    private func handleHorizontalTabSwipe(_ value: DragGesture.Value) {
        let horizontalDistance = value.translation.width
        let verticalDistance = value.translation.height
        guard abs(horizontalDistance) > max(abs(verticalDistance) * 1.35, 46) else {
            return
        }

        let modes = ViewerScreenMode.allCases
        guard let currentIndex = modes.firstIndex(of: selectedScreen) else { return }

        let nextIndex: Int
        if horizontalDistance < 0 {
            nextIndex = currentIndex - 1
        } else {
            nextIndex = currentIndex + 1
        }

        guard modes.indices.contains(nextIndex) else {
            showModeSwitcherBriefly()
            return
        }

        isVideoChromeHidden = false
        showModeSwitcherBriefly()
        withAnimation(screenTransitionAnimation) {
            selectedScreen = modes[nextIndex]
        }
    }

    private func showModeSwitcherBriefly() {
        let token = UUID()
        modeSwitcherVisibilityToken = token

        withAnimation(.easeInOut(duration: 0.14)) {
            isModeSwitcherTemporarilyVisible = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard modeSwitcherVisibilityToken == token,
                  selectedScreen != .menu else {
                return
            }

            withAnimation(.easeOut(duration: 1.0)) {
                isModeSwitcherTemporarilyVisible = false
            }
        }
    }

    private func menuScreen(topInset: CGFloat) -> some View {
        let uploadButtonTitle = service.isUploadingImages ? "Uploading…" : "Upload from iPhone"

        return ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                ViewerMenuCard {
                    HStack(alignment: .center, spacing: 16) {
                        Image("SnapletMark")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 64, height: 64)
                            .padding(12)
                            .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Snaplet")
                                .font(.system(size: 34, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)

                            Text("Use the fixed switcher above to jump between the dashboard, full-screen photo/video feeds, and favorites-only shuffles.")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                    }
                }

                ViewerMenuCard(title: "Connection", subtitle: service.hostName ?? "Looking for your Mac host") {
                    VStack(alignment: .leading, spacing: 14) {
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), spacing: 10),
                                GridItem(.flexible(), spacing: 10)
                            ],
                            spacing: 10
                        ) {
                            viewerMetricTile(
                                title: "Status",
                                value: service.connectionStatus,
                                subtitle: service.hostName == nil ? "Searching for your Mac host" : "Linked to your Mac host",
                                tint: Color(red: 0.95, green: 0.55, blue: 0.24)
                            )
                            viewerMetricTile(
                                title: "Indexed",
                                value: "\(service.libraryCount)",
                                subtitle: "Items reported by host",
                                tint: Color(red: 0.26, green: 0.63, blue: 0.49)
                            )
                            viewerMetricTile(
                                title: "Photo Queue",
                                value: photoQueueStatusValue,
                                subtitle: photoQueueStatusSubtitle,
                                tint: Color(red: 0.17, green: 0.45, blue: 0.76)
                            )
                            viewerMetricTile(
                                title: "Favorites Queue",
                                value: favoritePhotoQueueStatusValue,
                                subtitle: favoritePhotoQueueStatusSubtitle,
                                tint: Color(red: 0.21, green: 0.42, blue: 0.88)
                            )
                        }

                        Button {
                            service.restartDiscovery()
                        } label: {
                            Label("Reconnect to Host", systemImage: "arrow.clockwise")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(red: 0.89, green: 0.48, blue: 0.20))
                    }
                }

                ViewerMenuCard(title: "Library Stats", subtitle: "Photos, videos, favorites, and viewing activity.") {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 10),
                            GridItem(.flexible(), spacing: 10)
                        ],
                        spacing: 10
                    ) {
                        viewerMetricTile(
                            title: "Photos",
                            value: "\(service.libraryPhotoCount)",
                            subtitle: "\(service.libraryFavoritePhotoCount) favorite\(service.libraryFavoritePhotoCount == 1 ? "" : "s")",
                            tint: Color(red: 0.82, green: 0.38, blue: 0.18)
                        )
                        viewerMetricTile(
                            title: "Videos",
                            value: "\(service.libraryVideoCount)",
                            subtitle: "\(service.libraryFavoriteVideoCount) favorite\(service.libraryFavoriteVideoCount == 1 ? "" : "s")",
                            tint: Color(red: 0.28, green: 0.45, blue: 0.84)
                        )
                        viewerMetricTile(
                            title: "Viewed This Open",
                            value: "\(service.viewedSinceLastOpenCount)",
                            subtitle: "Since launching Snaplet",
                            tint: Color(red: 0.30, green: 0.62, blue: 0.50)
                        )
                        viewerMetricTile(
                            title: "Photos Today",
                            value: "\(service.viewedTodayPhotoCount)",
                            subtitle: "Photos viewed today",
                            tint: Color(red: 0.67, green: 0.42, blue: 0.86)
                        )
                        viewerMetricTile(
                            title: "Videos Today",
                            value: "\(service.viewedTodayVideoCount)",
                            subtitle: "Videos viewed today",
                            tint: Color(red: 0.67, green: 0.42, blue: 0.86)
                        )
                        viewerMetricTile(
                            title: "Time Today",
                            value: formattedAppUsageTime(service.timeSpentTodaySeconds),
                            subtitle: "Time spent in Snaplet",
                            tint: Color(red: 0.26, green: 0.58, blue: 0.78)
                        )
                    }
                }

                ViewerMenuCard(title: "Actions", subtitle: "Jump into the viewer or send up to 100 photos and videos to the Mac host.") {
                    VStack(spacing: 12) {
                        Button {
                            transitionToScreen(.photos)
                        } label: {
                            Label(service.currentAssetID == nil ? "Open Photos" : "Back to Photos", systemImage: "arrow.up.forward.app")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(red: 0.80, green: 0.38, blue: 0.15))

                        Button {
                            transitionToScreen(.videos)
                            service.setSelectionScope(.videos)
                            service.requestNextImage(in: .videos)
                        } label: {
                            Label("Load Random Video", systemImage: "shuffle")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)

                        PhotosPicker(
                            selection: $selectedUploadItems,
                            maxSelectionCount: 100,
                            matching: .any(of: [.images, .videos]),
                            preferredItemEncoding: .current,
                            photoLibrary: .shared()
                        ) {
                            Label(uploadButtonTitle, systemImage: "square.and.arrow.up")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)
                    }
                }

                ViewerMenuCard(title: "Current Media", subtitle: service.currentFilename ?? "No media loaded yet") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(service.currentFilename ?? "Switch to Photos or Videos, then swipe up to request a random item from your Mac.")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .lineLimit(3)

                        if service.currentAssetID != nil {
                            Text(service.currentImageIsFavorite ? "Marked as favorite" : "Not marked as favorite")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(service.currentImageIsFavorite ? Color.yellow.opacity(0.95) : .white.opacity(0.75))
                        }

                        if let currentMediaType = service.currentMediaType {
                            Text(currentMediaType == .photo ? "Photo" : "Video")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.8))
                        }

                        if let uploadStatusMessage = service.uploadStatusMessage {
                            Text(uploadStatusMessage)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color(red: 0.81, green: 0.95, blue: 0.84))
                        }

                        if let errorMessage = service.errorMessage {
                            Text(errorMessage)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color(red: 1.0, green: 0.78, blue: 0.72))
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, topInset + 44)
            .safeAreaPadding(.bottom, 28)
        }
    }

    @ViewBuilder
    private func viewerScreen(for mode: ViewerScreenMode, topInset: CGFloat) -> some View {
        let scope = mode.selectionScope ?? .all

        if mode == .videoAlbum && !isVideoCatalogPlayerPresented {
            videoCatalogScreen(for: mode, scope: videoAlbumScope)
        } else {
            videoPlayerScreen(for: mode, scope: scope, topInset: topInset)
        }
    }

    private func videoPlayerScreen(for mode: ViewerScreenMode, scope: ImageSelectionScope, topInset: CGFloat) -> some View {
        let catalogScope = videoAlbumScope
        let catalogPreviousAssetID = mode == .videoAlbum && isVideoCatalogPlayerPresented
            ? adjacentCatalogAssetID(from: service.currentAssetID, direction: .previous)
            : nil
        let catalogNextAssetID = mode == .videoAlbum && isVideoCatalogPlayerPresented
            ? adjacentCatalogAssetID(from: service.currentAssetID, direction: .next)
            : nil

        return ZStack {
            Color.black

            if let currentMediaType = service.currentMediaType {
                PagedMediaFeedSurface(
                    scope: scope,
                    currentAssetID: service.currentAssetID,
                    currentMediaType: currentMediaType,
                    currentImage: service.currentImage,
                    currentMediaURL: service.currentImageURL,
                    previousImage: service.previousImage,
                    nextImage: service.nextImage,
                    hasPreviousFrame: service.hasPreviousFrame || catalogPreviousAssetID != nil,
                    hasNextFrame: service.hasNextFrame || catalogNextAssetID != nil,
                    isVideoChromeHidden: isVideoChromeHidden,
                    onRequestNext: {
                        if let catalogNextAssetID {
                            service.requestVideo(assetID: catalogNextAssetID, in: catalogScope)
                        } else {
                            service.requestNextImage(in: scope)
                        }
                    },
                    onRequestPrevious: {
                        if let catalogPreviousAssetID {
                            service.requestVideo(assetID: catalogPreviousAssetID, in: catalogScope)
                        } else {
                            service.requestPreviousImage(in: scope)
                        }
                    },
                    onTransitionStateChanged: { isTransitioning in
                        isAnimatingFeedAdvance = isTransitioning
                    },
                    onVideoInteractionChanged: { isInteracting in
                        isInteractingWithVideoControls = isInteracting
                    },
                    onSurfaceTapped: {
                        guard scope.mediaType == .video else { return }
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isVideoChromeHidden.toggle()
                        }
                    },
                    onThumbnailRequested: {
                        presentThumbnailPickerForCurrentVideo()
                    }
                )
                .ignoresSafeArea()
            }

            LinearGradient(
                colors: [
                    .black.opacity(0.32),
                    .clear,
                    .black.opacity(0.18)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .overlay {
            if service.currentAssetID == nil && !service.isLoadingImage {
                VStack(spacing: 18) {
                    Image(systemName: mode.systemImage)
                        .font(.system(size: 54, weight: .regular))
                        .foregroundStyle(.white.opacity(0.88))

                    Text(mode.emptyStateTitle)
                        .font(.title.weight(.bold))
                        .foregroundStyle(.white)

                    Text(mode.emptyStateMessage)
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 28)

                    if let errorMessage = service.errorMessage {
                        Text(errorMessage)
                            .font(.footnote.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Color(red: 1.0, green: 0.80, blue: 0.75))
                            .padding(.horizontal, 32)
                    }

                    Button {
                        service.requestNextImage(in: scope)
                    } label: {
                        Label(loadButtonTitle(for: scope), systemImage: "arrow.up")
                            .font(.headline)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.89, green: 0.48, blue: 0.20))
                }
            }

            if service.isLoadingImage {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(1.5)
            }
        }
        .overlay(alignment: .topLeading) {
            if mode == .videoAlbum && isVideoCatalogPlayerPresented && !isVideoChromeHidden {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isVideoCatalogPlayerPresented = false
                        isVideoChromeHidden = false
                    }
                    service.requestVideoCatalog(scope: catalogScope, sort: videoCatalogSort)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(
                            Circle()
                                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .padding(.top, topInset + 52)
                .padding(.leading, 18)
            }
        }
        .overlay(alignment: .bottom) {
            if service.currentAssetID != nil && (scope.mediaType != .video || !isVideoChromeHidden) {
                HStack(spacing: 12) {
                    Button {
                        isPresentingDeleteConfirmation = true
                    } label: {
                        Group {
                            if service.isDeletingImage {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .tint(.white)
                            } else {
                                Image(systemName: "trash")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .frame(width: 42, height: 42)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(
                            Circle()
                                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(service.isUpdatingFavorite || service.isDeletingImage || isAnimatingFeedAdvance)

                    Button {
                        service.toggleFavorite()
                    } label: {
                        Group {
                            if service.isUpdatingFavorite {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .tint(.white)
                            } else {
                                Image(systemName: service.currentImageIsFavorite ? "star.fill" : "star")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(service.currentImageIsFavorite ? Color.yellow : .white)
                            }
                        }
                        .frame(width: 42, height: 42)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(
                            Circle()
                                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(service.isUpdatingFavorite || service.isDeletingImage || isAnimatingFeedAdvance)
                }
                .safeAreaPadding(.bottom, 18)
            }
        }
        .onChange(of: service.currentAssetID) { _, _ in
            viewerZoomScale = viewerMinimumZoomScale
            let resetTransaction = Transaction(animation: nil)
            withTransaction(resetTransaction) {
                feedDragOffset = 0
                isAnimatingFeedAdvance = false
                isInteractingWithVideoControls = false
            }
            clearPhotoTransitionCover()
        }
    }

    private func videoCatalogScreen(for mode: ViewerScreenMode, scope: ImageSelectionScope) -> some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Picker("Album Filter", selection: $videoAlbumFavoritesOnly) {
                        Text("All").tag(false)
                        Text("Favorites").tag(true)
                    }
                    .pickerStyle(.segmented)

                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            isVideoAlbumSelecting.toggle()
                            if isVideoAlbumSelecting == false {
                                selectedVideoCatalogAssetIDs = []
                            }
                        }
                    } label: {
                        Text(isVideoAlbumSelecting ? "Done" : "Select")
                            .font(.headline)
                            .frame(minWidth: 72)
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                }

                HStack(spacing: 12) {
                    Picker("Video Sort", selection: $videoCatalogSort) {
                        Text("Newest").tag(VideoCatalogSort.newest)
                        Text("Shortest").tag(VideoCatalogSort.durationAscending)
                        Text("Longest").tag(VideoCatalogSort.durationDescending)
                    }
                    .pickerStyle(.segmented)

                    if service.isLoadingVideoCatalog {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                    }
                }

                ForEach(service.videoCatalogItems) { item in
                    Button {
                        if isVideoAlbumSelecting {
                            toggleCatalogSelection(for: item.assetID)
                        } else {
                            openCatalogVideo(item, scope: scope)
                        }
                    } label: {
                        VideoCatalogRow(
                            item: item,
                            isSelecting: isVideoAlbumSelecting,
                            isSelected: selectedVideoCatalogAssetIDs.contains(item.assetID)
                        )
                    }
                    .buttonStyle(.plain)
                }

                if service.videoCatalogItems.isEmpty && !service.isLoadingVideoCatalog {
                    VStack(spacing: 16) {
                        Image(systemName: mode.systemImage)
                            .font(.system(size: 48, weight: .regular))
                            .foregroundStyle(.white.opacity(0.82))

                        Text(mode.emptyStateTitle)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)

                        if let errorMessage = service.errorMessage {
                            Text(errorMessage)
                                .font(.footnote.weight(.semibold))
                                .multilineTextAlignment(.center)
                                .foregroundStyle(Color(red: 1.0, green: 0.80, blue: 0.75))
                                .padding(.horizontal, 24)
                        }

                        Button {
                            service.requestVideoCatalog(scope: scope, sort: videoCatalogSort)
                        } label: {
                            Label("Reload", systemImage: "arrow.clockwise")
                                .font(.headline)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(red: 0.89, green: 0.48, blue: 0.20))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 90)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 104)
            .safeAreaPadding(.bottom, 28)
        }
        .background(Color.black)
        .overlay(alignment: .bottom) {
            if isVideoAlbumSelecting && selectedVideoCatalogAssetIDs.isEmpty == false {
                Button {
                    isPresentingAlbumDeleteConfirmation = true
                } label: {
                    Label(
                        "Delete \(selectedVideoCatalogAssetIDs.count)",
                        systemImage: service.isDeletingVideoCatalogItems ? "hourglass" : "trash"
                    )
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Color.red.opacity(0.92), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(service.isDeletingVideoCatalogItems)
                .padding(.horizontal, 18)
                .safeAreaPadding(.bottom, 18)
            }
        }
        .refreshable {
            service.requestVideoCatalog(scope: scope, sort: videoCatalogSort)
        }
        .task {
            if service.videoCatalogItems.isEmpty {
                service.requestVideoCatalog(scope: scope, sort: videoCatalogSort)
            }
        }
        .overlay {
            if service.isLoadingVideoCatalog && service.videoCatalogItems.isEmpty {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(1.4)
            }
        }
    }

    private func openCatalogVideo(_ item: VideoCatalogItem, scope: ImageSelectionScope) {
        service.setSelectionScope(scope)
        let resetTransaction = Transaction(animation: nil)
        withTransaction(resetTransaction) {
            feedDragOffset = 0
            isAnimatingFeedAdvance = false
            isInteractingWithVideoControls = false
            isVideoChromeHidden = false
        }

        withAnimation(.easeInOut(duration: 0.2)) {
            isVideoCatalogPlayerPresented = true
        }
        service.requestVideo(assetID: item.assetID, in: scope)
    }

    private func toggleCatalogSelection(for assetID: UUID) {
        if selectedVideoCatalogAssetIDs.contains(assetID) {
            selectedVideoCatalogAssetIDs.remove(assetID)
        } else {
            selectedVideoCatalogAssetIDs.insert(assetID)
        }
    }

    private func deleteSelectedCatalogVideos() {
        let assetIDs = Array(selectedVideoCatalogAssetIDs)
        selectedVideoCatalogAssetIDs = []
        isVideoAlbumSelecting = false
        service.deleteVideoCatalogItems(assetIDs: assetIDs)
    }

    private func adjacentCatalogAssetID(
        from assetID: UUID?,
        direction: VideoCatalogNavigationDirection
    ) -> UUID? {
        guard let assetID,
              let index = service.videoCatalogItems.firstIndex(where: { $0.assetID == assetID }) else {
            return nil
        }

        switch direction {
        case .previous:
            guard index > service.videoCatalogItems.startIndex else { return nil }
            return service.videoCatalogItems[service.videoCatalogItems.index(before: index)].assetID
        case .next:
            let nextIndex = service.videoCatalogItems.index(after: index)
            guard nextIndex < service.videoCatalogItems.endIndex else { return nil }
            return service.videoCatalogItems[nextIndex].assetID
        }
    }

    private func presentThumbnailPickerForCurrentVideo() {
        guard let assetID = service.currentAssetID,
              service.currentMediaType == .video else {
            return
        }

        pendingThumbnailAssetID = assetID
        isPresentingThumbnailPicker = true
    }

    @MainActor
    private func prepareVideoThumbnail(from item: PhotosPickerItem) async {
        guard let assetID = pendingThumbnailAssetID else { return }
        pendingThumbnailAssetID = nil

        guard let payload = await loadPayload(from: item) else { return }
        await MainActor.run {
            service.uploadVideoThumbnail(assetID: assetID, payload: payload)
        }
    }

    private func handleFeedSwipeEnded(
        for scope: ImageSelectionScope,
        translation: CGFloat,
        verticalVelocity: CGFloat,
        viewportHeight: CGFloat,
        enabled: Bool,
        canLoadPrevious: Bool
    ) {
        guard enabled else {
            withAnimation(feedReturnAnimation) {
                feedDragOffset = 0
            }
            return
        }

        let dragThreshold = min(max(viewportHeight * 0.028, 18), 28)
        let projectedTranslation = translation + (verticalVelocity * 0.12)
        let shouldLoadPrevious = canLoadPrevious && projectedTranslation > dragThreshold
        let shouldLoadNext = projectedTranslation < -dragThreshold

        guard shouldLoadPrevious || shouldLoadNext else {
            withAnimation(feedReturnAnimation) {
                feedDragOffset = 0
            }
            return
        }

        if shouldLoadPrevious {
            retreatFeed(in: scope, viewportHeight: viewportHeight)
        } else {
            advanceFeed(in: scope, viewportHeight: viewportHeight)
        }
    }

    private func advanceFeed(in scope: ImageSelectionScope, viewportHeight: CGFloat) {
        guard !isAnimatingFeedAdvance else { return }

        if let nextImage = service.nextImage {
            isAnimatingFeedAdvance = true
            animateFeedOffsetChange(to: -viewportHeight, animation: feedSlideAnimation) {
                if service.currentMediaType == .photo {
                    preparePhotoTransitionCover(using: nextImage)
                }
                service.requestNextImage(in: scope)
                resetFeedAnimationState()
            }
            return
        }

        animateFeedOffsetChange(to: -min(max(viewportHeight * 0.04, 20), 44), animation: feedNudgeAnimation) {
            service.requestNextImage(in: scope)
            withAnimation(feedReturnAnimation) {
                feedDragOffset = 0
            }
        }
    }

    private func retreatFeed(in scope: ImageSelectionScope, viewportHeight: CGFloat) {
        guard !isAnimatingFeedAdvance else { return }

        isAnimatingFeedAdvance = true
        animateFeedOffsetChange(to: viewportHeight, animation: feedSlideAnimation) {
            if service.currentMediaType == .photo, let previousImage = service.previousImage {
                preparePhotoTransitionCover(using: previousImage)
            }
            service.requestPreviousImage(in: scope)
            resetFeedAnimationState()
        }
    }

    private func transitionToScreen(_ screen: ViewerScreenMode) {
        guard selectedScreen != screen else { return }

        withAnimation(screenTransitionAnimation) {
            selectedScreen = screen
        }
    }

    private func animateFeedOffsetChange(
        to targetOffset: CGFloat,
        animation: Animation,
        completion: @escaping () -> Void = {}
    ) {
        var transaction = Transaction(animation: animation)
        transaction.addAnimationCompletion(criteria: .logicallyComplete) {
            completion()
        }

        withTransaction(transaction) {
            feedDragOffset = targetOffset
        }
    }

    private func resetFeedAnimationState() {
        let resetTransaction = Transaction(animation: nil)
        withTransaction(resetTransaction) {
            feedDragOffset = 0
            isAnimatingFeedAdvance = false
        }
    }

    private func preparePhotoTransitionCover(using image: UIImage) {
        photoTransitionCoverImage = image
        photoTransitionCoverOpacity = 1
        awaitingPhotoTransitionAssetID = nil
        latestReadyPhotoAssetID = nil
        photoTransitionCoverToken = UUID()
    }

    private func handlePhotoAssetReady(_ assetID: UUID) {
        latestReadyPhotoAssetID = assetID

        guard awaitingPhotoTransitionAssetID == assetID else { return }
        schedulePhotoTransitionCoverClear(for: assetID)
    }

    private func clearPhotoTransitionCover() {
        photoTransitionCoverImage = nil
        photoTransitionCoverOpacity = 1
        awaitingPhotoTransitionAssetID = nil
        latestReadyPhotoAssetID = nil
        photoTransitionCoverToken = UUID()
    }

    private func schedulePhotoTransitionCoverClear(for assetID: UUID) {
        let token = photoTransitionCoverToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard photoTransitionCoverToken == token,
                  awaitingPhotoTransitionAssetID == assetID,
                  photoTransitionCoverImage != nil else {
                return
            }

            withAnimation(.linear(duration: 0.08)) {
                photoTransitionCoverOpacity = 0
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
                guard photoTransitionCoverToken == token,
                      awaitingPhotoTransitionAssetID == assetID else {
                    return
                }

                clearPhotoTransitionCover()
            }
        }
    }

    private func loadButtonTitle(for scope: ImageSelectionScope) -> String {
        switch (scope.mediaType, scope.favoritesOnly) {
        case (.photo, false):
            "Load First Photo"
        case (.photo, true):
            "Load Favorite Photo"
        case (.video, false):
            "Load First Video"
        case (.video, true):
            "Load Favorite Video"
        }
    }

    private func releasePrompt(for scope: ImageSelectionScope) -> String {
        switch (scope.mediaType, scope.favoritesOnly) {
        case (.photo, false):
            "Release to load the next random photo"
        case (.photo, true):
            "Release to load the next favorite photo"
        case (.video, false):
            "Release to load the next random video"
        case (.video, true):
            "Release to load the next favorite video"
        }
    }

    private func viewerMetricTile(title: String, value: String, subtitle: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.62))

            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.72)

            Text(subtitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(tint.opacity(0.26))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                )
        )
    }

    private func formattedAppUsageTime(_ seconds: TimeInterval) -> String {
        let totalMinutes = max(Int(seconds / 60), 0)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }

        if seconds > 0 && totalMinutes == 0 {
            return "<1m"
        }

        return "\(minutes)m"
    }

    private var photoQueueStatusValue: String {
        "\(service.photoPrefetchQueueCount)/\(service.photoPrefetchQueueTargetCount)"
    }

    private var photoQueueStatusSubtitle: String {
        let readyCount = service.photoPrefetchQueueCount
        return "\(readyCount) regular photo\(readyCount == 1 ? "" : "s") ready"
    }

    private var favoritePhotoQueueStatusValue: String {
        "\(service.favoritePhotoPrefetchQueueCount)/\(service.favoritePhotoPrefetchQueueTargetCount)"
    }

    private var favoritePhotoQueueStatusSubtitle: String {
        let readyCount = service.favoritePhotoPrefetchQueueCount
        return "\(readyCount) favorite photo\(readyCount == 1 ? "" : "s") ready"
    }

    private func prepareUploads(from items: [PhotosPickerItem]) async {
        let payloads = await withTaskGroup(of: ImageUploadPayload?.self, returning: [ImageUploadPayload].self) { group in
            for item in items {
                group.addTask {
                    await loadPayload(from: item)
                }
            }

            var payloads: [ImageUploadPayload] = []
            for await payload in group {
                if let payload {
                    payloads.append(payload)
                }
            }
            return payloads
        }

        guard !payloads.isEmpty else { return }
        await MainActor.run {
            service.uploadImages(payloads)
        }
    }

    private func loadPayload(from item: PhotosPickerItem) async -> ImageUploadPayload? {
        guard let selectedFile = try? await item.loadTransferable(type: SelectedUploadFile.self) else {
            return nil
        }
        return ImageUploadPayload(
            filename: selectedFile.filename,
            temporaryFileURL: selectedFile.fileURL
        )
    }
}

private struct VideoCatalogRow: View {
    let item: VideoCatalogItem
    let isSelecting: Bool
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(isSelected ? Color(red: 0.96, green: 0.53, blue: 0.24) : .white.opacity(0.72))
                    .frame(width: 28)
            }

            ZStack(alignment: .bottomTrailing) {
                AsyncImage(url: item.thumbnailURL) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        thumbnailPlaceholder
                    case .empty:
                        ZStack {
                            thumbnailPlaceholder
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.white)
                        }
                    @unknown default:
                        thumbnailPlaceholder
                    }
                }
                .frame(width: 132, height: 74)
                .clipped()
                .background(Color.white.opacity(0.08))

                Text(durationText)
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.74), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .padding(5)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                Text(item.originalFilename)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 8) {
                    Label(fileSizeText, systemImage: "externaldrive")
                    if item.isFavorite {
                        Label("Favorite", systemImage: "star.fill")
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }

            Spacer(minLength: 0)

            if isSelecting == false {
                Image(systemName: "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 34, height: 34)
                    .background(Color.white, in: Circle())
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
    }

    private var thumbnailPlaceholder: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.13, green: 0.16, blue: 0.20),
                    Color(red: 0.28, green: 0.18, blue: 0.14)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))
        }
    }

    private var durationText: String {
        guard let durationSeconds = item.durationSeconds,
              durationSeconds.isFinite,
              durationSeconds > 0 else {
            return "--:--"
        }

        let totalSeconds = Int(durationSeconds.rounded(.down))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }

        return String(format: "%d:%02d", minutes, seconds)
    }

    private var fileSizeText: String {
        ByteCountFormatter.string(fromByteCount: item.byteSize, countStyle: .file)
    }
}

private struct MediaFeedSnapshot {
    let scope: ImageSelectionScope
    let currentAssetID: UUID?
    let currentMediaType: MediaType
    let currentImage: UIImage?
    let currentMediaURL: URL?
    let previousImage: UIImage?
    let nextImage: UIImage?
    let hasPreviousFrame: Bool
    let hasNextFrame: Bool
    let isVideoChromeHidden: Bool

    var hasPreviousPage: Bool {
        if currentMediaType == .video {
            return hasPreviousFrame
        }

        return previousImage != nil
    }

    var hasNextPage: Bool {
        if currentMediaType == .video {
            return currentAssetID != nil || hasNextFrame
        }

        return nextImage != nil
    }
}

private struct PagedMediaFeedSurface: UIViewRepresentable {
    let scope: ImageSelectionScope
    let currentAssetID: UUID?
    let currentMediaType: MediaType
    let currentImage: UIImage?
    let currentMediaURL: URL?
    let previousImage: UIImage?
    let nextImage: UIImage?
    let hasPreviousFrame: Bool
    let hasNextFrame: Bool
    let isVideoChromeHidden: Bool
    let onRequestNext: () -> Void
    let onRequestPrevious: () -> Void
    let onTransitionStateChanged: (Bool) -> Void
    let onVideoInteractionChanged: (Bool) -> Void
    let onSurfaceTapped: () -> Void
    let onThumbnailRequested: () -> Void

    func makeUIView(context: Context) -> PagedMediaFeedView {
        PagedMediaFeedView()
    }

    func updateUIView(_ uiView: PagedMediaFeedView, context: Context) {
        uiView.onRequestNext = onRequestNext
        uiView.onRequestPrevious = onRequestPrevious
        uiView.onTransitionStateChanged = onTransitionStateChanged
        uiView.onVideoInteractionChanged = onVideoInteractionChanged
        uiView.onSurfaceTapped = onSurfaceTapped
        uiView.onThumbnailRequested = onThumbnailRequested
        uiView.update(
            snapshot: MediaFeedSnapshot(
                scope: scope,
                currentAssetID: currentAssetID,
                currentMediaType: currentMediaType,
                currentImage: currentImage,
                currentMediaURL: currentMediaURL,
                previousImage: previousImage,
                nextImage: nextImage,
                hasPreviousFrame: hasPreviousFrame,
                hasNextFrame: hasNextFrame,
                isVideoChromeHidden: isVideoChromeHidden
            )
        )
    }
}

private enum MediaFeedCommitDirection {
    case forward
    case backward
}

private final class FeedPagingScrollView: UIScrollView {
    var shouldBeginPagingPan: ((UIPanGestureRecognizer) -> Bool)?

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === panGestureRecognizer else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }

        if let shouldBeginPagingPan {
            return shouldBeginPagingPan(panGestureRecognizer)
        }

        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}

private final class PagedMediaFeedView: UIView, UIScrollViewDelegate {
    private let scrollView = FeedPagingScrollView()
    private var previousPageView = FeedPageView()
    private var currentPageView = FeedPageView()
    private var nextPageView = FeedPageView()

    private var currentSnapshot: MediaFeedSnapshot?
    private var displayedAssetID: UUID?
    private var displayedScope: ImageSelectionScope?
    private var displayedMediaType: MediaType?
    private var pendingDirection: MediaFeedCommitDirection?
    private var isAwaitingCommittedAsset = false
    private var isVideoInteractionActive = false
    private var pagingDragStartOffsetY: CGFloat = 0

    var onRequestNext: (() -> Void)?
    var onRequestPrevious: (() -> Void)?
    var onTransitionStateChanged: ((Bool) -> Void)?
    var onVideoInteractionChanged: ((Bool) -> Void)?
    var onSurfaceTapped: (() -> Void)?
    var onThumbnailRequested: (() -> Void)?

    private lazy var surfaceTapGestureRecognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleSurfaceTap(_:)))
        recognizer.cancelsTouchesInView = false
        return recognizer
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)

        backgroundColor = .clear

        scrollView.backgroundColor = .clear
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.alwaysBounceVertical = true
        scrollView.isPagingEnabled = true
        scrollView.clipsToBounds = true
        scrollView.decelerationRate = .fast
        scrollView.delegate = self
        scrollView.shouldBeginPagingPan = { [weak self] panGestureRecognizer in
            self?.shouldBeginPaging(with: panGestureRecognizer) ?? false
        }
        addSubview(scrollView)
        addGestureRecognizer(surfaceTapGestureRecognizer)

        scrollView.addSubview(previousPageView)
        scrollView.addSubview(currentPageView)
        scrollView.addSubview(nextPageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        layoutPageViews()
        if scrollView.isDragging == false && scrollView.isDecelerating == false {
            recenter()
        }
    }

    func update(snapshot: MediaFeedSnapshot) {
        currentSnapshot = snapshot

        let scopeChanged = displayedScope != snapshot.scope || displayedMediaType != snapshot.currentMediaType
        let assetChanged = displayedAssetID != snapshot.currentAssetID

        if pendingDirection != nil {
            guard assetChanged else {
                updateScrollState()
                return
            }

            refreshVisiblePages(with: snapshot)
            pendingDirection = nil
            isAwaitingCommittedAsset = false
            onTransitionStateChanged?(false)
        } else if scopeChanged || assetChanged {
            refreshVisiblePages(with: snapshot)
            onTransitionStateChanged?(false)
        } else {
            refreshVisiblePages(with: snapshot)
        }

        displayedAssetID = snapshot.currentAssetID
        displayedScope = snapshot.scope
        displayedMediaType = snapshot.currentMediaType
        updateScrollState()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        finishPagingIfNeeded()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        pagingDragStartOffsetY = scrollView.contentOffset.y
    }

    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        guard let snapshot = currentSnapshot,
              snapshot.currentAssetID != nil,
              isAwaitingCommittedAsset == false else {
            return
        }

        let pageHeight = max(bounds.height, 1)
        let currentDelta = scrollView.contentOffset.y - pagingDragStartOffsetY
        let panVelocityY = scrollView.panGestureRecognizer.velocity(in: self).y
        let threshold = min(max(pageHeight * 0.035, 18), 34)
        let shouldAdvance = snapshot.hasNextPage && (currentDelta > threshold || panVelocityY < -160)
        let shouldRetreat = snapshot.hasPreviousPage && (currentDelta < -threshold || panVelocityY > 160)

        if shouldAdvance {
            targetContentOffset.pointee.y = pageHeight * 2
        } else if shouldRetreat {
            targetContentOffset.pointee.y = 0
        } else {
            targetContentOffset.pointee.y = pageHeight
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if decelerate == false {
            finishPagingIfNeeded()
        }
    }

    private func shouldBeginPaging(with panGestureRecognizer: UIPanGestureRecognizer) -> Bool {
        guard let snapshot = currentSnapshot,
              snapshot.currentAssetID != nil,
              isAwaitingCommittedAsset == false else {
            return false
        }

        let velocity = panGestureRecognizer.velocity(in: self)
        guard abs(velocity.y) > abs(velocity.x) else {
            return false
        }

        let direction = velocity.y < 0 ? MediaFeedCommitDirection.forward : .backward
        switch direction {
        case .forward:
            guard snapshot.hasNextPage else { return false }
        case .backward:
            guard snapshot.hasPreviousPage else { return false }
        }

        let location = panGestureRecognizer.location(in: currentPageView)
        return currentPageView.allowsExternalPaging(at: location)
    }

    private func finishPagingIfNeeded() {
        guard isAwaitingCommittedAsset == false,
              let snapshot = currentSnapshot else {
            recenter()
            return
        }

        let pageIndex = Int(round(scrollView.contentOffset.y / max(bounds.height, 1)))
        switch pageIndex {
        case 2 where snapshot.hasNextPage:
            commitPaging(direction: .forward, mediaType: snapshot.currentMediaType)
        case 0 where snapshot.hasPreviousPage:
            commitPaging(direction: .backward, mediaType: snapshot.currentMediaType)
        default:
            recenter()
        }
    }

    private func commitPaging(direction: MediaFeedCommitDirection, mediaType: MediaType) {
        guard pendingDirection == nil else { return }

        pendingDirection = direction
        isAwaitingCommittedAsset = true
        onTransitionStateChanged?(true)

        switch direction {
        case .forward:
            let recycledPage = previousPageView
            previousPageView = currentPageView
            currentPageView = nextPageView
            nextPageView = recycledPage
            previousPageView.demoteCurrentToPreview(mediaType: mediaType)
            currentPageView.promotePreviewToCurrentPlaceholder(mediaType: mediaType)
            nextPageView.clear()
            onRequestNext?()
        case .backward:
            let recycledPage = nextPageView
            nextPageView = currentPageView
            currentPageView = previousPageView
            previousPageView = recycledPage
            nextPageView.demoteCurrentToPreview(mediaType: mediaType)
            currentPageView.promotePreviewToCurrentPlaceholder(mediaType: mediaType)
            previousPageView.clear()
            onRequestPrevious?()
        }

        layoutPageViews()
        recenter()
        updateScrollState()
    }

    private func refreshVisiblePages(with snapshot: MediaFeedSnapshot) {
        previousPageView.onVideoInteractionChanged = nil
        currentPageView.onVideoInteractionChanged = { [weak self] isInteracting in
            guard let self else { return }
            isVideoInteractionActive = isInteracting
            onVideoInteractionChanged?(isInteracting)
            updateScrollState()
        }
        currentPageView.onThumbnailRequested = { [weak self] in
            self?.onThumbnailRequested?()
        }
        nextPageView.onVideoInteractionChanged = nil
        previousPageView.onThumbnailRequested = nil
        nextPageView.onThumbnailRequested = nil

        previousPageView.configureAdjacentPreview(
            mediaType: snapshot.currentMediaType,
            image: snapshot.previousImage
        )
        currentPageView.configureCurrent(
            mediaType: snapshot.currentMediaType,
            assetID: snapshot.currentAssetID,
            image: snapshot.currentImage,
            mediaURL: snapshot.currentMediaURL,
            controlsHidden: snapshot.isVideoChromeHidden
        )
        nextPageView.configureAdjacentPreview(
            mediaType: snapshot.currentMediaType,
            image: snapshot.nextImage
        )

        if snapshot.currentMediaType != .video {
            isVideoInteractionActive = false
            onVideoInteractionChanged?(false)
        }

        layoutPageViews()
        if scrollView.isDragging == false && scrollView.isDecelerating == false {
            recenter()
        }
    }

    private func updateScrollState() {
        let canScroll = currentSnapshot?.currentAssetID != nil
            && isAwaitingCommittedAsset == false
            && isVideoInteractionActive == false
        scrollView.isScrollEnabled = canScroll
    }

    @objc
    private func handleSurfaceTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended,
              currentSnapshot?.currentMediaType == .video else {
            return
        }

        let location = recognizer.location(in: currentPageView)
        guard currentPageView.allowsChromeToggle(at: location) else { return }
        onSurfaceTapped?()
    }

    private func layoutPageViews() {
        let pageWidth = bounds.width
        let pageHeight = bounds.height

        scrollView.contentSize = CGSize(width: pageWidth, height: pageHeight * 3)
        previousPageView.frame = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        currentPageView.frame = CGRect(x: 0, y: pageHeight, width: pageWidth, height: pageHeight)
        nextPageView.frame = CGRect(x: 0, y: pageHeight * 2, width: pageWidth, height: pageHeight)
    }

    private func recenter() {
        let targetOffset = CGPoint(x: 0, y: bounds.height)
        guard scrollView.contentOffset != targetOffset else { return }
        scrollView.setContentOffset(targetOffset, animated: false)
    }
}

private enum FeedPageContentKind {
    case empty
    case photo
    case video
    case preview
    case loading
}

private final class FeedPageView: UIView {
    private let previewImageView = UIImageView()
    private let loadingIndicator = UIActivityIndicatorView(style: .large)
    private let photoView = ZoomableImageSurfaceView()
    private let videoView = AutoplayVideoSurfaceView()

    private var contentKind: FeedPageContentKind = .empty
    private var renderedImage: UIImage?
    private var renderedAssetID: UUID?
    private var renderedVideoURL: URL?
    private var previewDisplayToken = UUID()

    var onVideoInteractionChanged: ((Bool) -> Void)? {
        didSet {
            videoView.onInteractionChanged = onVideoInteractionChanged
        }
    }

    var onThumbnailRequested: (() -> Void)? {
        didSet {
            videoView.onThumbnailRequested = onThumbnailRequested
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        backgroundColor = .clear

        previewImageView.contentMode = .scaleAspectFit
        previewImageView.clipsToBounds = true
        previewImageView.backgroundColor = .clear
        addSubview(previewImageView)

        loadingIndicator.color = .white
        loadingIndicator.hidesWhenStopped = true
        addSubview(loadingIndicator)

        photoView.isHidden = true
        photoView.usesExternalFeedPaging = true
        addSubview(photoView)

        videoView.isHidden = true
        videoView.usesExternalFeedPaging = true
        addSubview(videoView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewImageView.frame = bounds
        loadingIndicator.center = CGPoint(x: bounds.midX, y: bounds.midY)
        photoView.frame = bounds
        videoView.frame = bounds
    }

    func configureCurrent(
        mediaType: MediaType,
        assetID: UUID?,
        image: UIImage?,
        mediaURL: URL?,
        controlsHidden: Bool
    ) {
        switch mediaType {
        case .photo:
            guard let image else {
                clear()
                return
            }

            if contentKind == .photo,
               renderedImage === image {
                renderedAssetID = assetID
                if let assetID {
                    photoView.adoptDisplayedAssetID(assetID)
                }
                setPhotoInteractive(true)
                photoView.recenterIfAtMinimumZoom()
                showPhotoView()
                return
            }

            renderPhoto(
                image: image,
                displayID: assetID ?? renderedAssetID ?? previewDisplayToken,
                interactive: true
            )
            renderedAssetID = assetID
        case .video:
            guard let assetID, let mediaURL else {
                showPreviewImage(image)
                return
            }

            if contentKind == .video && renderedAssetID == assetID && renderedVideoURL == mediaURL {
                videoView.isSwipeEnabled = true
                videoView.setControlsHidden(controlsHidden, animated: true)
                videoView.updateInteractionMode()
                return
            }

            renderVideo(
                assetID: assetID,
                url: mediaURL,
                previewImage: image,
                interactive: true,
                controlsHidden: controlsHidden
            )
        }
    }

    func configureAdjacentPreview(mediaType: MediaType, image: UIImage?) {
        switch mediaType {
        case .photo:
            showPreviewImage(image)
        case .video:
            if let image {
                showPreviewImage(image)
            } else {
                showLoadingPlaceholder()
            }
        }
    }

    func promotePreviewToCurrentPlaceholder(mediaType: MediaType) {
        switch mediaType {
        case .photo:
            if contentKind == .photo {
                setPhotoInteractive(true)
                photoView.recenterIfAtMinimumZoom()
                showPhotoView()
            } else {
                showPreviewImage(renderedImage)
            }
        case .video:
            if contentKind != .video {
                showLoadingPlaceholder()
            }
        }
    }

    func demoteCurrentToPreview(mediaType: MediaType) {
        switch mediaType {
        case .photo:
            showPreviewImage(renderedImage)
        case .video:
            showPreviewImage(renderedImage)
        }
    }

    func clear() {
        previewImageView.image = nil
        previewImageView.isHidden = false
        loadingIndicator.stopAnimating()
        loadingIndicator.isHidden = true

        photoView.isUserInteractionEnabled = false
        photoView.isSwipeEnabled = false
        photoView.updateInteractionMode()
        photoView.isHidden = true

        videoView.prepareForReuse()
        videoView.isHidden = true

        contentKind = .empty
        renderedImage = nil
        renderedAssetID = nil
        renderedVideoURL = nil
    }

    func allowsExternalPaging(at point: CGPoint) -> Bool {
        switch contentKind {
        case .photo:
            return photoView.allowsExternalPaging
        case .video:
            return videoView.allowsExternalPaging(at: convert(point, to: videoView))
        case .preview, .empty, .loading:
            return true
        }
    }

    func allowsChromeToggle(at point: CGPoint) -> Bool {
        switch contentKind {
        case .video:
            return videoView.allowsChromeToggle(at: convert(point, to: videoView))
        case .photo, .preview, .empty, .loading:
            return true
        }
    }

    private func renderPhoto(image: UIImage, displayID: UUID, interactive: Bool) {
        if contentKind == .video {
            videoView.prepareForReuse()
        }

        contentKind = .photo
        renderedImage = image
        renderedAssetID = nil
        previewDisplayToken = displayID
        renderedVideoURL = nil

        previewImageView.isHidden = true
        loadingIndicator.stopAnimating()
        loadingIndicator.isHidden = true
        videoView.isHidden = true
        photoView.isHidden = false
        photoView.display(image: image, assetID: displayID)
        setPhotoInteractive(interactive)
    }

    private func renderVideo(
        assetID: UUID,
        url: URL,
        previewImage: UIImage?,
        interactive: Bool,
        controlsHidden: Bool
    ) {
        contentKind = .video
        renderedImage = previewImage
        renderedAssetID = assetID
        renderedVideoURL = url

        previewImageView.isHidden = true
        loadingIndicator.stopAnimating()
        loadingIndicator.isHidden = true
        photoView.isHidden = true
        videoView.isHidden = false
        videoView.isSwipeEnabled = interactive
        videoView.setControlsHidden(controlsHidden, animated: false)
        videoView.displayVideo(at: url, assetID: assetID, previewImage: previewImage)
        videoView.updateInteractionMode()
    }

    private func showPreviewImage(_ image: UIImage?) {
        if contentKind == .video {
            videoView.prepareForReuse()
        }

        contentKind = image == nil ? .empty : .preview
        renderedImage = image
        renderedAssetID = nil
        renderedVideoURL = nil

        photoView.isUserInteractionEnabled = false
        photoView.isSwipeEnabled = false
        photoView.updateInteractionMode()
        photoView.isHidden = true
        videoView.isHidden = true
        loadingIndicator.stopAnimating()
        loadingIndicator.isHidden = true

        previewImageView.image = image
        previewImageView.isHidden = false
    }

    private func showLoadingPlaceholder() {
        if contentKind == .video {
            videoView.prepareForReuse()
        }

        contentKind = .loading
        renderedImage = nil
        renderedAssetID = nil
        renderedVideoURL = nil

        photoView.isUserInteractionEnabled = false
        photoView.isSwipeEnabled = false
        photoView.updateInteractionMode()
        photoView.isHidden = true
        videoView.isHidden = true
        previewImageView.image = nil
        previewImageView.isHidden = false
        loadingIndicator.isHidden = false
        loadingIndicator.startAnimating()
    }

    private func setPhotoInteractive(_ interactive: Bool) {
        photoView.isUserInteractionEnabled = interactive
        photoView.isSwipeEnabled = interactive
        photoView.updateInteractionMode()
    }

    private func showPhotoView() {
        previewImageView.isHidden = true
        videoView.isHidden = true
        photoView.isHidden = false
    }
}

private struct ZoomableImageSurface: UIViewRepresentable {
    let image: UIImage
    let assetID: UUID
    let isSwipeEnabled: Bool
    let onSwipeChanged: (CGFloat) -> Void
    let onSwipeEnded: (CGFloat, CGFloat) -> Void
    @Binding var zoomScale: CGFloat
    @Binding var minimumZoomScale: CGFloat
    let onAssetReady: (UUID) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> ZoomableImageSurfaceView {
        let view = ZoomableImageSurfaceView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: ZoomableImageSurfaceView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.attach(to: uiView)
        uiView.isSwipeEnabled = isSwipeEnabled
        uiView.onSwipeChanged = onSwipeChanged
        uiView.onSwipeEnded = onSwipeEnded
        uiView.onAssetReady = onAssetReady
        uiView.display(image: image, assetID: assetID)
        uiView.updateInteractionMode()
        context.coordinator.publishZoomState(
            zoomScale: uiView.scrollView.zoomScale,
            minimumZoomScale: uiView.scrollView.minimumZoomScale
        )
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: ZoomableImageSurface
        weak var surfaceView: ZoomableImageSurfaceView?

        init(parent: ZoomableImageSurface) {
            self.parent = parent
        }

        func attach(to view: ZoomableImageSurfaceView) {
            surfaceView = view
            view.onZoomStateChanged = { [weak self] zoomScale, minimumZoomScale in
                self?.publishZoomState(
                    zoomScale: zoomScale,
                    minimumZoomScale: minimumZoomScale
                )
            }
        }

        func publishZoomState(zoomScale currentZoomScale: CGFloat, minimumZoomScale currentMinimumZoomScale: CGFloat) {

            if abs(parent.zoomScale - currentZoomScale) < 0.0001,
               abs(parent.minimumZoomScale - currentMinimumZoomScale) < 0.0001 {
                return
            }

            parent.zoomScale = currentZoomScale
            parent.minimumZoomScale = currentMinimumZoomScale
        }
    }
}

private struct StaticImageSurface: View {
    let image: UIImage

    var body: some View {
        GeometryReader { proxy in
            let fittedSize = fittedImageSize(for: image, in: proxy.size)

            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: fittedSize.width, height: fittedSize.height)
                .position(x: proxy.size.width * 0.5, y: proxy.size.height * 0.5)
        }
        .ignoresSafeArea()
    }

    private func fittedImageSize(for image: UIImage, in viewportSize: CGSize) -> CGSize {
        let imageWidth = max(image.size.width, 1)
        let imageHeight = max(image.size.height, 1)
        let widthScale = viewportSize.width / imageWidth
        let heightScale = viewportSize.height / imageHeight
        let scale = min(min(widthScale, heightScale), 1)

        return CGSize(
            width: imageWidth * scale,
            height: imageHeight * scale
        )
    }
}

private struct AutoplayVideoSurface: UIViewRepresentable {
    let assetID: UUID
    let videoURL: URL
    let previewImage: UIImage?
    let isSwipeEnabled: Bool
    let onSwipeChanged: (CGFloat) -> Void
    let onSwipeEnded: (CGFloat, CGFloat) -> Void
    let onInteractionChanged: (Bool) -> Void

    func makeUIView(context: Context) -> AutoplayVideoSurfaceView {
        let view = AutoplayVideoSurfaceView()
        view.isSwipeEnabled = isSwipeEnabled
        view.onSwipeChanged = onSwipeChanged
        view.onSwipeEnded = onSwipeEnded
        view.onInteractionChanged = onInteractionChanged
        return view
    }

    func updateUIView(_ uiView: AutoplayVideoSurfaceView, context: Context) {
        uiView.isSwipeEnabled = isSwipeEnabled
        uiView.onSwipeChanged = onSwipeChanged
        uiView.onSwipeEnded = onSwipeEnded
        uiView.onInteractionChanged = onInteractionChanged
        uiView.displayVideo(
            at: videoURL,
            assetID: assetID,
            previewImage: previewImage
        )
    }

    static func dismantleUIView(_ uiView: AutoplayVideoSurfaceView, coordinator: ()) {
        DispatchQueue.main.async {
            uiView.prepareForReuse()
        }
    }
}

private final class AutoplayVideoSurfaceView: UIView, UIGestureRecognizerDelegate {
    private let previewImageView = UIImageView()
    private let playerLayer = AVPlayerLayer()
    private let controlsContainer = UIView()
    private let playPauseButton = UIButton(type: .system)
    private let muteButton = UIButton(type: .system)
    private let thumbnailButton = UIButton(type: .system)
    private let currentTimeLabel = UILabel()
    private let durationLabel = UILabel()
    private let seekSlider = UISlider()

    private var currentAssetID: UUID?
    private var currentVideoURL: URL?
    private var loopObserver: NSObjectProtocol?
    private var playerTimeObserver: Any?
    private var itemStatusObserver: NSKeyValueObservation?
    private var itemDurationObserver: NSKeyValueObservation?
    private var isScrubbing = false
    private var shouldResumePlaybackAfterScrub = false
    private var isManuallyPaused = false
    private var isMuted = false
    private var knownDurationSeconds: Double = 0
    private lazy var swipePanGestureRecognizer: UIPanGestureRecognizer = {
        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handleSwipePan(_:)))
        recognizer.delegate = self
        recognizer.cancelsTouchesInView = true
        recognizer.minimumNumberOfTouches = 1
        recognizer.maximumNumberOfTouches = 1
        return recognizer
    }()

    var isSwipeEnabled = false
    var usesExternalFeedPaging = false
    var onSwipeChanged: ((CGFloat) -> Void)?
    var onSwipeEnded: ((CGFloat, CGFloat) -> Void)?
    var onInteractionChanged: ((Bool) -> Void)?
    var onThumbnailRequested: (() -> Void)?
    private var controlsAreHidden = false

    override init(frame: CGRect) {
        super.init(frame: frame)

        backgroundColor = .black

        previewImageView.contentMode = .scaleAspectFit
        previewImageView.clipsToBounds = true
        addSubview(previewImageView)

        playerLayer.videoGravity = .resizeAspect
        layer.addSublayer(playerLayer)

        controlsContainer.translatesAutoresizingMaskIntoConstraints = false
        controlsContainer.backgroundColor = UIColor.black.withAlphaComponent(0.42)
        controlsContainer.layer.cornerRadius = 18
        controlsContainer.layer.cornerCurve = .continuous
        controlsContainer.layer.borderWidth = 1
        controlsContainer.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
        addSubview(controlsContainer)
        addGestureRecognizer(swipePanGestureRecognizer)

        configureControlButton(playPauseButton, systemImageName: "pause.fill")
        playPauseButton.addTarget(self, action: #selector(togglePlayPause), for: .touchUpInside)

        configureControlButton(muteButton, systemImageName: "speaker.wave.2.fill")
        muteButton.addTarget(self, action: #selector(toggleMute), for: .touchUpInside)

        configureControlButton(thumbnailButton, systemImageName: "photo.badge.plus")
        thumbnailButton.addTarget(self, action: #selector(requestThumbnailChange), for: .touchUpInside)

        currentTimeLabel.translatesAutoresizingMaskIntoConstraints = false
        currentTimeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        currentTimeLabel.textColor = .white
        currentTimeLabel.textAlignment = .left
        currentTimeLabel.text = Self.formattedPlaybackTime(0)

        durationLabel.translatesAutoresizingMaskIntoConstraints = false
        durationLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        durationLabel.textColor = UIColor.white.withAlphaComponent(0.88)
        durationLabel.textAlignment = .right
        durationLabel.text = "--:--"

        seekSlider.translatesAutoresizingMaskIntoConstraints = false
        seekSlider.minimumValue = 0
        seekSlider.maximumValue = 1
        seekSlider.value = 0
        seekSlider.minimumTrackTintColor = UIColor(red: 0.96, green: 0.53, blue: 0.24, alpha: 1)
        seekSlider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.24)
        seekSlider.isEnabled = false
        seekSlider.addTarget(self, action: #selector(handleScrubTouchDown), for: .touchDown)
        seekSlider.addTarget(self, action: #selector(handleScrubValueChanged(_:)), for: .valueChanged)
        seekSlider.addTarget(self, action: #selector(handleScrubTouchEnded(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])

        let controlsStack = UIStackView(arrangedSubviews: [playPauseButton, muteButton, thumbnailButton, currentTimeLabel, seekSlider, durationLabel])
        controlsStack.translatesAutoresizingMaskIntoConstraints = false
        controlsStack.axis = .horizontal
        controlsStack.alignment = .center
        controlsStack.spacing = 10
        controlsContainer.addSubview(controlsStack)

        playPauseButton.widthAnchor.constraint(equalToConstant: 34).isActive = true
        muteButton.widthAnchor.constraint(equalToConstant: 34).isActive = true
        thumbnailButton.widthAnchor.constraint(equalToConstant: 34).isActive = true
        currentTimeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        durationLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        currentTimeLabel.setContentHuggingPriority(.required, for: .horizontal)
        durationLabel.setContentHuggingPriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            controlsContainer.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 18),
            controlsContainer.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -18),
            controlsContainer.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -84),

            controlsStack.leadingAnchor.constraint(equalTo: controlsContainer.leadingAnchor, constant: 14),
            controlsStack.trailingAnchor.constraint(equalTo: controlsContainer.trailingAnchor, constant: -14),
            controlsStack.topAnchor.constraint(equalTo: controlsContainer.topAnchor, constant: 12),
            controlsStack.bottomAnchor.constraint(equalTo: controlsContainer.bottomAnchor, constant: -12),

            currentTimeLabel.widthAnchor.constraint(equalToConstant: 56),
            durationLabel.widthAnchor.constraint(equalToConstant: 56),
            seekSlider.heightAnchor.constraint(greaterThanOrEqualToConstant: 30)
        ])

        configureAudioSession()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewImageView.frame = bounds
        playerLayer.frame = bounds
    }

    func displayVideo(at url: URL, assetID: UUID, previewImage: UIImage?) {
        previewImageView.image = previewImage

        guard currentAssetID != assetID || currentVideoURL != url else {
            if isManuallyPaused == false {
                playerLayer.player?.play()
            }
            return
        }

        prepareForReuse()

        currentAssetID = assetID
        currentVideoURL = url
        knownDurationSeconds = 0
        isManuallyPaused = false
        resetControls()
        updateInteractionMode()

        let playerItem = AVPlayerItem(url: url)
        playerItem.preferredForwardBufferDuration = 1
        let player = AVPlayer(playerItem: playerItem)
        player.actionAtItemEnd = .none
        player.isMuted = isMuted
        player.automaticallyWaitsToMinimizeStalling = false
        playerLayer.player = player

        observePlayback(for: player, item: playerItem)

        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self, weak player] _ in
            DispatchQueue.main.async {
                guard let self else { return }

                player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                    guard finished else { return }

                    DispatchQueue.main.async {
                        self.updateDisplayedCurrentTime(0)
                        self.seekSlider.value = 0
                        if self.isScrubbing == false && self.isManuallyPaused == false {
                            player?.playImmediately(atRate: 1)
                        }
                    }
                }
            }
        }

        player.playImmediately(atRate: 1)
    }

    func setControlsHidden(_ hidden: Bool, animated: Bool) {
        controlsAreHidden = hidden
        let updates = {
            self.controlsContainer.alpha = hidden ? 0 : 1
        }

        if animated {
            UIView.animate(withDuration: 0.18, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut], animations: updates)
        } else {
            updates()
        }

        controlsContainer.isUserInteractionEnabled = !hidden
    }

    func prepareForReuse() {
        cleanupPlayback()
        previewImageView.image = nil
        currentAssetID = nil
        currentVideoURL = nil
        knownDurationSeconds = 0
        resetControls()
        updateInteractionMode()
    }

    private func cleanupPlayback() {
        onInteractionChanged?(false)
        isScrubbing = false
        shouldResumePlaybackAfterScrub = false
        isManuallyPaused = false
        itemStatusObserver = nil
        itemDurationObserver = nil

        if let loopObserver {
            NotificationCenter.default.removeObserver(loopObserver)
            self.loopObserver = nil
        }

        if let player = playerLayer.player, let playerTimeObserver {
            player.removeTimeObserver(playerTimeObserver)
            self.playerTimeObserver = nil
        }

        playerLayer.player?.pause()
        playerLayer.player?.replaceCurrentItem(with: nil)
        playerLayer.player = nil
    }

    private func observePlayback(for player: AVPlayer, item: AVPlayerItem) {
        itemStatusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] observedItem, _ in
            DispatchQueue.main.async {
                self?.refreshPlaybackReadiness(for: observedItem)
            }
        }

        itemDurationObserver = item.observe(\.duration, options: [.initial, .new]) { [weak self] observedItem, _ in
            DispatchQueue.main.async {
                self?.refreshKnownDuration(from: observedItem.duration)
            }
        }

        playerTimeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.15, preferredTimescale: 600),
            queue: .main
        ) { [weak self, weak player] currentTime in
            DispatchQueue.main.async {
                guard let self else { return }

                if let duration = player?.currentItem?.duration {
                    self.refreshKnownDuration(from: duration)
                }

                guard self.isScrubbing == false else { return }
                self.updateDisplayedCurrentTime(currentTime.seconds)
            }
        }
    }

    private func refreshPlaybackReadiness(for item: AVPlayerItem) {
        guard item.status == .readyToPlay else { return }
        refreshKnownDuration(from: item.duration)
    }

    private func refreshKnownDuration(from duration: CMTime) {
        let durationSeconds = duration.seconds
        guard durationSeconds.isFinite, durationSeconds > 0 else { return }

        knownDurationSeconds = durationSeconds
        seekSlider.maximumValue = Float(durationSeconds)
        durationLabel.text = Self.formattedPlaybackTime(durationSeconds)
        seekSlider.isEnabled = true
    }

    private func resetControls() {
        seekSlider.minimumValue = 0
        seekSlider.maximumValue = 1
        seekSlider.value = 0
        seekSlider.isEnabled = false
        currentTimeLabel.text = Self.formattedPlaybackTime(0)
        durationLabel.text = "--:--"
        updatePlaybackButtons()
    }

    private func configureControlButton(_ button: UIButton, systemImageName: String) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.tintColor = .white
        button.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        button.layer.cornerRadius = 17
        button.layer.cornerCurve = .continuous
        button.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold),
            forImageIn: .normal
        )
        button.setImage(UIImage(systemName: systemImageName), for: .normal)
        button.heightAnchor.constraint(equalToConstant: 34).isActive = true
    }

    private func configureAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func updatePlaybackButtons() {
        let playPauseImage = isManuallyPaused ? "play.fill" : "pause.fill"
        let muteImage = isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        playPauseButton.setImage(UIImage(systemName: playPauseImage), for: .normal)
        muteButton.setImage(UIImage(systemName: muteImage), for: .normal)
    }

    @objc
    private func togglePlayPause() {
        guard let player = playerLayer.player else { return }

        isManuallyPaused.toggle()
        if isManuallyPaused {
            player.pause()
        } else {
            player.playImmediately(atRate: 1)
        }
        updatePlaybackButtons()
    }

    @objc
    private func toggleMute() {
        isMuted.toggle()
        playerLayer.player?.isMuted = isMuted
        updatePlaybackButtons()
    }

    @objc
    private func requestThumbnailChange() {
        onThumbnailRequested?()
    }

    func updateInteractionMode() {
        swipePanGestureRecognizer.isEnabled = usesExternalFeedPaging == false && isSwipeEnabled && !isScrubbing
    }

    private func updateDisplayedCurrentTime(_ seconds: Double) {
        guard seconds.isFinite else { return }

        let clampedSeconds: Double
        if knownDurationSeconds > 0 {
            clampedSeconds = min(max(seconds, 0), knownDurationSeconds)
        } else {
            clampedSeconds = max(seconds, 0)
        }

        currentTimeLabel.text = Self.formattedPlaybackTime(clampedSeconds)
        if isScrubbing == false {
            seekSlider.value = Float(clampedSeconds)
        }
    }

    private func seek(to seconds: Double, shouldResumePlayback: Bool) {
        guard let player = playerLayer.player else { return }

        let clampedSeconds: Double
        if knownDurationSeconds > 0 {
            clampedSeconds = min(max(seconds, 0), knownDurationSeconds)
        } else {
            clampedSeconds = max(seconds, 0)
        }

        let targetTime = CMTime(seconds: clampedSeconds, preferredTimescale: 600)
        let seekTolerance = CMTime(seconds: 0.15, preferredTimescale: 600)
        player.seek(to: targetTime, toleranceBefore: seekTolerance, toleranceAfter: seekTolerance) { [weak self, weak player] finished in
            guard finished else { return }

            DispatchQueue.main.async {
                guard let self else { return }

                self.updateDisplayedCurrentTime(clampedSeconds)
                if shouldResumePlayback && self.isManuallyPaused == false {
                    player?.playImmediately(atRate: 1)
                }
            }
        }
    }

    @objc
    private func handleScrubTouchDown() {
        guard playerLayer.player != nil else { return }

        isScrubbing = true
        shouldResumePlaybackAfterScrub = isManuallyPaused == false && playerLayer.player?.timeControlStatus != .paused
        playerLayer.player?.pause()
        onInteractionChanged?(true)
        updateInteractionMode()
    }

    @objc
    private func handleScrubValueChanged(_ sender: UISlider) {
        guard isScrubbing else { return }
        updateDisplayedCurrentTime(Double(sender.value))
    }

    @objc
    private func handleScrubTouchEnded(_ sender: UISlider) {
        guard isScrubbing else { return }

        isScrubbing = false
        onInteractionChanged?(false)
        updateInteractionMode()
        seek(to: Double(sender.value), shouldResumePlayback: shouldResumePlaybackAfterScrub)
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === swipePanGestureRecognizer else {
            return true
        }

        let location = gestureRecognizer.location(in: self)
        guard controlsAreHidden || controlsContainer.frame.insetBy(dx: -16, dy: -12).contains(location) == false else {
            return false
        }

        let velocity = swipePanGestureRecognizer.velocity(in: self)
        return isSwipeEnabled && abs(velocity.y) > abs(velocity.x)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === swipePanGestureRecognizer else {
            return true
        }

        let location = touch.location(in: self)
        return controlsAreHidden || controlsContainer.frame.insetBy(dx: -16, dy: -12).contains(location) == false
    }

    @objc
    private func handleSwipePan(_ recognizer: UIPanGestureRecognizer) {
        guard isSwipeEnabled else { return }

        let translationY = recognizer.translation(in: self).y
        let velocityY = recognizer.velocity(in: self).y

        switch recognizer.state {
        case .changed:
            onSwipeChanged?(translationY)
        case .cancelled, .ended, .failed:
            onSwipeEnded?(translationY, velocityY)
        default:
            break
        }
    }

    private static func formattedPlaybackTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else {
            return "--:--"
        }

        let totalSeconds = Int(seconds.rounded(.down))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let remainingSeconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }

        return String(format: "%d:%02d", minutes, remainingSeconds)
    }

    func allowsExternalPaging(at point: CGPoint) -> Bool {
        guard isSwipeEnabled, isScrubbing == false else { return false }
        return controlsAreHidden || controlsContainer.frame.insetBy(dx: -16, dy: -12).contains(point) == false
    }

    func allowsChromeToggle(at point: CGPoint) -> Bool {
        return controlsAreHidden || controlsContainer.frame.insetBy(dx: -16, dy: -12).contains(point) == false
    }
}

private final class ZoomableImageSurfaceView: UIView, UIGestureRecognizerDelegate, UIScrollViewDelegate {
    let scrollView = UIScrollView()
    let imageView = UIImageView()

    var isSwipeEnabled = false
    var usesExternalFeedPaging = false
    var onSwipeChanged: ((CGFloat) -> Void)?
    var onSwipeEnded: ((CGFloat, CGFloat) -> Void)?
    var onAssetReady: ((UUID) -> Void)?
    var onZoomStateChanged: ((CGFloat, CGFloat) -> Void)?

    private var currentAssetID: UUID?
    private var sourceImageSize: CGSize = .zero
    private var fittedImageSize: CGSize = .zero
    private var needsZoomReset = false
    private var lastBoundsSize: CGSize = .zero
    private var pendingReadyAssetID: UUID?
    private var centeringStabilizationToken: UUID?
    private lazy var swipePanGestureRecognizer: UIPanGestureRecognizer = {
        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handleSwipePan(_:)))
        recognizer.delegate = self
        recognizer.cancelsTouchesInView = true
        recognizer.minimumNumberOfTouches = 1
        recognizer.maximumNumberOfTouches = 1
        return recognizer
    }()
    private lazy var doubleTapGestureRecognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        recognizer.numberOfTapsRequired = 2
        recognizer.delegate = self
        return recognizer
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)

        backgroundColor = .clear

        scrollView.backgroundColor = .clear
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.bouncesZoom = true
        scrollView.bounces = true
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.delaysContentTouches = false
        scrollView.clipsToBounds = false
        scrollView.delegate = self

        imageView.backgroundColor = .clear
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = false

        addSubview(scrollView)
        scrollView.addSubview(imageView)
        scrollView.addGestureRecognizer(swipePanGestureRecognizer)
        scrollView.addGestureRecognizer(doubleTapGestureRecognizer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds

        let boundsChanged = abs(lastBoundsSize.width - bounds.width) > 0.5
            || abs(lastBoundsSize.height - bounds.height) > 0.5
        let shouldRefitImage = boundsChanged

        updateZoomScales(resetZoom: shouldRefitImage)
        if shouldRefitImage, let currentAssetID {
            scheduleCenteringStabilization(for: currentAssetID)
        }
        lastBoundsSize = bounds.size
    }

    func display(image: UIImage, assetID: UUID) {
        let isNewAsset = currentAssetID != assetID
        let incomingImageSize = CGSize(
            width: max(image.size.width, 1),
            height: max(image.size.height, 1)
        )
        let imageObjectChanged = imageView.image !== image
        let imageSizeChanged = abs(sourceImageSize.width - incomingImageSize.width) > 0.5
            || abs(sourceImageSize.height - incomingImageSize.height) > 0.5
        currentAssetID = assetID

        if isNewAsset || imageObjectChanged || imageSizeChanged {
            imageView.image = image
            sourceImageSize = incomingImageSize
        }

        if isNewAsset {
            imageView.isHidden = true
            pendingReadyAssetID = assetID
            scrollView.contentInset = .zero
            scrollView.contentOffset = .zero
        }

        if isNewAsset || imageSizeChanged {
            needsZoomReset = true
        }

        let shouldStabilizeCentering = isNewAsset || imageSizeChanged
        updateZoomScales(resetZoom: shouldStabilizeCentering)
        if shouldStabilizeCentering {
            scheduleCenteringStabilization(for: assetID)
        }
        updateInteractionMode()
    }

    func centerImageIfNeeded() {
        syncContentGeometry()
        let displayedSize = displayedImageSize()
        let horizontalInset = max((bounds.width - displayedSize.width) * 0.5, 0)
        let verticalInset = max((bounds.height - displayedSize.height) * 0.5, 0)

        scrollView.contentInset = UIEdgeInsets(
            top: verticalInset,
            left: horizontalInset,
            bottom: verticalInset,
            right: horizontalInset
        )
    }

    private func updateZoomScales(resetZoom: Bool) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        guard sourceImageSize.width > 0, sourceImageSize.height > 0 else { return }

        let widthScale = bounds.width / sourceImageSize.width
        let heightScale = bounds.height / sourceImageSize.height
        let fitScale = min(widthScale, heightScale)
        let targetFittedSize = CGSize(
            width: max(sourceImageSize.width * fitScale, 1),
            height: max(sourceImageSize.height * fitScale, 1)
        )

        if abs(fittedImageSize.width - targetFittedSize.width) > 0.5
            || abs(fittedImageSize.height - targetFittedSize.height) > 0.5 {
            fittedImageSize = targetFittedSize
            imageView.frame = CGRect(origin: .zero, size: targetFittedSize)
            scrollView.contentSize = targetFittedSize
        }

        let minimumScale: CGFloat = 1
        let maximumScale = max(minimumScale * 8, 4)
        let currentScale = scrollView.zoomScale == 0 ? minimumScale : scrollView.zoomScale
        let clampedScale = min(max(currentScale, minimumScale), maximumScale)

        scrollView.minimumZoomScale = minimumScale
        scrollView.maximumZoomScale = maximumScale

        let shouldResetZoom = resetZoom || needsZoomReset
        let targetScale = shouldResetZoom ? minimumScale : clampedScale
        if abs(scrollView.zoomScale - targetScale) > 0.0001 {
            scrollView.setZoomScale(targetScale, animated: false)
        }

        centerImageIfNeeded()
        if shouldResetZoom {
            scrollView.contentOffset = centeredContentOffset()
            needsZoomReset = false
        } else {
            scrollView.contentOffset = clampedContentOffset(scrollView.contentOffset)
        }

        imageView.isHidden = false
        if let pendingReadyAssetID {
            self.pendingReadyAssetID = nil
            onAssetReady?(pendingReadyAssetID)
        }
        publishZoomState()
        updateInteractionMode()
    }

    private func centeredContentOffset() -> CGPoint {
        CGPoint(
            x: -scrollView.contentInset.left,
            y: -scrollView.contentInset.top
        )
    }

    private func clampedContentOffset(_ proposedOffset: CGPoint) -> CGPoint {
        let displayedSize = displayedImageSize()
        let scaledContentWidth = displayedSize.width
        let scaledContentHeight = displayedSize.height
        let minOffsetX = -scrollView.contentInset.left
        let minOffsetY = -scrollView.contentInset.top
        let maxOffsetX = max(scaledContentWidth - bounds.width + scrollView.contentInset.right, minOffsetX)
        let maxOffsetY = max(scaledContentHeight - bounds.height + scrollView.contentInset.bottom, minOffsetY)

        return CGPoint(
            x: min(max(proposedOffset.x, minOffsetX), maxOffsetX),
            y: min(max(proposedOffset.y, minOffsetY), maxOffsetY)
        )
    }

    private func displayedImageSize() -> CGSize {
        imageView.frame.size
    }

    func updateInteractionMode() {
        let shouldOwnFeedSwipe = allowsExternalPaging
        scrollView.panGestureRecognizer.isEnabled = isSwipeEnabled && !shouldOwnFeedSwipe
        scrollView.pinchGestureRecognizer?.isEnabled = isSwipeEnabled
        doubleTapGestureRecognizer.isEnabled = isSwipeEnabled
        swipePanGestureRecognizer.isEnabled = usesExternalFeedPaging == false && shouldOwnFeedSwipe
    }

    func recenterIfAtMinimumZoom() {
        guard currentAssetID != nil else { return }
        guard scrollView.zoomScale <= (scrollView.minimumZoomScale + 0.01) else { return }
        centerImageIfNeeded()
        scrollView.contentOffset = centeredContentOffset()
        publishZoomState()
        updateInteractionMode()
    }

    func resetToMinimumZoom() {
        guard currentAssetID != nil else { return }

        let minimumZoomScale = scrollView.minimumZoomScale
        if minimumZoomScale > 0, abs(scrollView.zoomScale - minimumZoomScale) > 0.0001 {
            scrollView.setZoomScale(minimumZoomScale, animated: false)
        }

        centerImageIfNeeded()
        scrollView.contentOffset = centeredContentOffset()
        publishZoomState()
        updateInteractionMode()
    }

    func adoptDisplayedAssetID(_ assetID: UUID) {
        currentAssetID = assetID
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        syncContentGeometry()
        centerImageIfNeeded()
        scrollView.contentOffset = clampedContentOffset(scrollView.contentOffset)
        publishZoomState()
        updateInteractionMode()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        publishZoomState()
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === swipePanGestureRecognizer else {
            return true
        }

        let velocity = swipePanGestureRecognizer.velocity(in: scrollView)
        return isSwipeEnabled && abs(velocity.y) > abs(velocity.x)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer === swipePanGestureRecognizer || otherGestureRecognizer === swipePanGestureRecognizer
    }

    @objc
    private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        let minimumZoomScale = scrollView.minimumZoomScale
        if scrollView.zoomScale > (minimumZoomScale + 0.01) {
            scrollView.setZoomScale(minimumZoomScale, animated: true)
            return
        }

        let targetZoomScale = min(max(minimumZoomScale * 2.5, minimumZoomScale + 0.5), scrollView.maximumZoomScale)
        guard targetZoomScale > minimumZoomScale + 0.01 else { return }

        let tapPoint = recognizer.location(in: imageView)
        let zoomRect = CGRect(
            x: tapPoint.x - ((bounds.width / targetZoomScale) * 0.5),
            y: tapPoint.y - ((bounds.height / targetZoomScale) * 0.5),
            width: bounds.width / targetZoomScale,
            height: bounds.height / targetZoomScale
        )
        scrollView.zoom(to: zoomRect, animated: true)
    }

    @objc
    private func handleSwipePan(_ recognizer: UIPanGestureRecognizer) {
        guard isSwipeEnabled else { return }

        let translationY = recognizer.translation(in: scrollView).y
        let velocityY = recognizer.velocity(in: scrollView).y

        switch recognizer.state {
        case .changed:
            onSwipeChanged?(translationY)
        case .cancelled, .ended, .failed:
            onSwipeEnded?(translationY, velocityY)
        default:
            break
        }
    }

    var allowsExternalPaging: Bool {
        isSwipeEnabled && scrollView.zoomScale <= (scrollView.minimumZoomScale + 0.01)
    }

    private func publishZoomState() {
        onZoomStateChanged?(scrollView.zoomScale, scrollView.minimumZoomScale)
    }

    private func syncContentGeometry() {
        let displayedSize = CGSize(
            width: max(imageView.frame.width, 1),
            height: max(imageView.frame.height, 1)
        )

        if abs(scrollView.contentSize.width - displayedSize.width) > 0.5
            || abs(scrollView.contentSize.height - displayedSize.height) > 0.5 {
            scrollView.contentSize = displayedSize
        }
    }

    private func scheduleCenteringStabilization(for assetID: UUID) {
        let token = UUID()
        centeringStabilizationToken = token
        let delays: [TimeInterval] = [0, 0.05, 0.15, 0.3, 0.5]

        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                guard centeringStabilizationToken == token,
                      currentAssetID == assetID else {
                    return
                }

                layoutIfNeeded()
                recenterIfAtMinimumZoom()
            }
        }
    }
}

private struct SelectedUploadFile: Transferable {
    let filename: String
    let fileURL: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image, importing: makeSelectedUploadFile)
        FileRepresentation(importedContentType: .movie, importing: makeSelectedUploadFile)
        FileRepresentation(importedContentType: .video, importing: makeSelectedUploadFile)
    }

    private static func makeSelectedUploadFile(_ received: ReceivedTransferredFile) throws -> SelectedUploadFile {
        let sourceURL = received.file
        let sourceFilename = sourceURL.lastPathComponent
        let fallbackFilename = sourceURL.pathExtension.isEmpty
            ? "iphone-\(UUID().uuidString)"
            : "iphone-\(UUID().uuidString).\(sourceURL.pathExtension)"
        let filename = sourceFilename.isEmpty ? fallbackFilename : sourceFilename
        let destinationURL = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)-\(filename)")

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

        return SelectedUploadFile(filename: filename, fileURL: destinationURL)
    }
}

private struct ViewerModeSwitcher: View {
    @Binding var selectedMode: ViewerScreenMode

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(ViewerScreenMode.allCases) { mode in
                    Button {
                        withAnimation(.easeInOut(duration: 0.24)) {
                            selectedMode = mode
                        }
                    } label: {
                        Label(mode.rawValue, systemImage: mode.systemImage)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(selectedMode == mode ? Color.black : .white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(selectedMode == mode ? .white : .white.opacity(0.08))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(3)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 16, x: 0, y: 10)
    }
}

private struct ViewerMenuCard<Content: View>: View {
    let title: String?
    let subtitle: String?
    @ViewBuilder let content: Content

    init(
        title: String? = nil,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.62))
            }

            if let subtitle {
                Text(subtitle)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
            }

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.white.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.22), radius: 24, x: 0, y: 18)
        )
    }
}
