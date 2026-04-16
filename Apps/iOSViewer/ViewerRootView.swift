import SwiftUI
import CoreTransferable
import PhotosUI
import UIKit

private enum ViewerScreenMode: String, CaseIterable, Identifiable {
    case menu = "Menu"
    case feed = "Feed"
    case favorites = "Favorites"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .menu:
            "slider.horizontal.3"
        case .feed:
            "rectangle.stack.fill"
        case .favorites:
            "star.fill"
        }
    }

    var selectionScope: ImageSelectionScope? {
        switch self {
        case .menu:
            nil
        case .feed:
            .all
        case .favorites:
            .favorites
        }
    }

    var emptyStateTitle: String {
        switch self {
        case .menu:
            "Menu"
        case .feed:
            "No Image Yet"
        case .favorites:
            "No Favorite Images"
        }
    }

    var emptyStateMessage: String {
        switch self {
        case .menu:
            ""
        case .feed:
            "Swipe up to pull a random image from your Mac host."
        case .favorites:
            "Mark images with the star in Feed, then switch back here for a favorites-only shuffle."
        }
    }
}

struct ViewerRootView: View {
    @StateObject private var service: PeerViewerService
    @State private var feedDragOffset: CGFloat = 0
    @State private var isAnimatingFeedAdvance = false
    @State private var selectedUploadItems: [PhotosPickerItem] = []
    @State private var selectedScreen: ViewerScreenMode = .menu
    @State private var viewerZoomScale: CGFloat = 1
    @State private var viewerMinimumZoomScale: CGFloat = 1
    @State private var isPresentingDeleteConfirmation = false

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
                    switch selectedScreen {
                    case .menu:
                        menuScreen(topInset: topInset)
                            .transition(.opacity.combined(with: .move(edge: .leading)))
                    case .feed:
                        viewerScreen(for: .feed)
                            .transition(.opacity.combined(with: .move(edge: .trailing)))
                    case .favorites:
                        viewerScreen(for: .favorites)
                            .transition(.opacity.combined(with: .move(edge: .trailing)))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

                ViewerModeSwitcher(selectedMode: $selectedScreen)
                    .frame(maxWidth: 324)
                    .padding(.horizontal, 18)
                    .padding(.top, topInset + 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: selectedScreen)
        .onAppear {
            service.start()
        }
        .onDisappear {
            service.stop()
        }
        .onChange(of: selectedScreen) { _, screen in
            let resetTransaction = Transaction(animation: nil)
            withTransaction(resetTransaction) {
                feedDragOffset = 0
                isAnimatingFeedAdvance = false
            }
            guard let scope = screen.selectionScope else { return }
            service.setSelectionScope(scope)
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
        .confirmationDialog(
            "Delete this image from the Mac library?",
            isPresented: $isPresentingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Image", role: .destructive) {
                service.deleteCurrentImage()
            }
        } message: {
            Text("This removes the image from the Mac host and deletes the underlying file as well.")
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
            case .feed, .favorites:
                Color.black
            }
        }
        .ignoresSafeArea()
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

                            Text("Use the fixed switcher above to jump between the dashboard, the full-screen feed, and your favorites-only shuffle.")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                    }
                }

                ViewerMenuCard(title: "Connection", subtitle: service.hostName ?? "Looking for your Mac host") {
                    VStack(alignment: .leading, spacing: 14) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                viewerInfoChip(service.connectionStatus, tint: Color(red: 0.95, green: 0.55, blue: 0.24))
                                viewerInfoChip("\(service.libraryCount) indexed", tint: Color(red: 0.26, green: 0.63, blue: 0.49))
                                if service.isPrefetching {
                                    viewerInfoChip("preloading", tint: Color(red: 0.21, green: 0.42, blue: 0.88))
                                }
                            }
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

                ViewerMenuCard(title: "Actions", subtitle: "Jump into the viewer or send up to 100 lossless images to the Mac host.") {
                    VStack(spacing: 12) {
                        Button {
                            withAnimation(.spring(response: 0.38, dampingFraction: 0.84)) {
                                selectedScreen = .feed
                            }
                        } label: {
                            Label(service.currentImage == nil ? "Open Feed" : "Back to Feed", systemImage: "arrow.up.forward.app")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(red: 0.80, green: 0.38, blue: 0.15))

                        Button {
                            withAnimation(.spring(response: 0.38, dampingFraction: 0.84)) {
                                selectedScreen = .feed
                            }
                            service.setSelectionScope(.all)
                            service.requestNextImage(in: .all)
                        } label: {
                            Label("Load Random Image", systemImage: "shuffle")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)

                        PhotosPicker(
                            selection: $selectedUploadItems,
                            maxSelectionCount: 100,
                            matching: .images,
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

                ViewerMenuCard(title: "Current Image", subtitle: service.currentFilename ?? "No image loaded yet") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(service.currentFilename ?? "Switch to Feed, then swipe up to request a random image from your Mac.")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .lineLimit(3)

                        if service.currentAssetID != nil {
                            Text(service.currentImageIsFavorite ? "Marked as favorite" : "Not marked as favorite")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(service.currentImageIsFavorite ? Color.yellow.opacity(0.95) : .white.opacity(0.75))
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

    private func viewerScreen(for mode: ViewerScreenMode) -> some View {
        let scope = mode.selectionScope ?? .all

        return GeometryReader { proxy in
            let viewportHeight = max(proxy.size.height, 1)
            let canSwipeFeed = service.currentImage != nil
                && viewerZoomScale <= (viewerMinimumZoomScale + 0.01)
                && !isAnimatingFeedAdvance
            let canSwipeToPrevious = service.previousImage != nil

            ZStack {
                Color.black

                if let previousImage = service.previousImage {
                    StaticImageSurface(image: previousImage)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .offset(y: -viewportHeight + max(feedDragOffset, 0))
                        .allowsHitTesting(false)
                }

                if let currentImage = service.currentImage, let assetID = service.currentAssetID {
                    if let nextImage = service.nextImage {
                        StaticImageSurface(image: nextImage)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .offset(y: viewportHeight + min(feedDragOffset, 0))
                            .allowsHitTesting(false)
                    }

                    ZoomableImageSurface(
                        image: currentImage,
                        assetID: assetID,
                        isSwipeEnabled: canSwipeFeed,
                        onSwipeChanged: { translation in
                            if translation < 0 {
                                feedDragOffset = max(translation, -viewportHeight)
                            } else if canSwipeToPrevious {
                                feedDragOffset = min(translation, viewportHeight)
                            } else {
                                feedDragOffset = 0
                            }
                        },
                        onSwipeEnded: { translation, verticalVelocity in
                            handleFeedSwipeEnded(
                                for: scope,
                                translation: translation,
                                verticalVelocity: verticalVelocity,
                                viewportHeight: viewportHeight,
                                enabled: canSwipeFeed,
                                canLoadPrevious: canSwipeToPrevious
                            )
                        },
                        zoomScale: $viewerZoomScale,
                        minimumZoomScale: $viewerMinimumZoomScale
                    )
                    .id(assetID)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .offset(y: feedDragOffset)
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
            .highPriorityGesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        guard canSwipeFeed else { return }

                        let translation = value.translation.height
                        if translation < 0 {
                            feedDragOffset = max(translation, -viewportHeight)
                        } else if canSwipeToPrevious {
                            feedDragOffset = min(translation, viewportHeight)
                        } else {
                            feedDragOffset = 0
                        }
                    }
                    .onEnded { value in
                        guard canSwipeFeed else { return }

                        let translation = value.translation.height
                        let estimatedVelocity = (value.predictedEndTranslation.height - translation) / 0.12
                        handleFeedSwipeEnded(
                            for: scope,
                            translation: translation,
                            verticalVelocity: estimatedVelocity,
                            viewportHeight: viewportHeight,
                            enabled: canSwipeFeed,
                            canLoadPrevious: canSwipeToPrevious
                        )
                    }
            )
            .overlay {
                if service.currentImage == nil && !service.isLoadingImage {
                    VStack(spacing: 18) {
                        Image(systemName: mode == .favorites ? "star.square.on.square" : "photo.on.rectangle.angled")
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
                            Label(scope == .favorites ? "Load Favorite" : "Load First Image", systemImage: "arrow.up")
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
            .overlay(alignment: .bottom) {
                VStack(spacing: 10) {
                    if canSwipeFeed && abs(feedDragOffset) > 8 {
                        Text(feedDragOffset > 0
                            ? "Release to return to the previous image"
                            : (scope == .favorites ? "Release to load the next favorite image" : "Release to load the next random image"))
                            .font(.headline)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(.black.opacity(0.52))
                            )
                    }

                    if service.currentAssetID != nil {
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
                    }
                }
                .safeAreaPadding(.bottom, 18)
            }
            .onChange(of: service.currentAssetID) { _, _ in
                viewerZoomScale = viewerMinimumZoomScale
                let resetTransaction = Transaction(animation: nil)
                withTransaction(resetTransaction) {
                    feedDragOffset = 0
                    isAnimatingFeedAdvance = false
                }
            }
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
            withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.9, blendDuration: 0.08)) {
                feedDragOffset = 0
            }
            return
        }

        let dragThreshold = min(max(viewportHeight * 0.028, 18), 28)
        let projectedTranslation = translation + (verticalVelocity * 0.12)
        let shouldLoadPrevious = canLoadPrevious && projectedTranslation > dragThreshold
        let shouldLoadNext = projectedTranslation < -dragThreshold

        guard shouldLoadPrevious || shouldLoadNext else {
            withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.9, blendDuration: 0.08)) {
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

        if service.nextImage != nil {
            isAnimatingFeedAdvance = true
            withAnimation(.timingCurve(0.22, 0.92, 0.28, 1, duration: 0.22)) {
                feedDragOffset = -viewportHeight
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                service.requestNextImage(in: scope)
                let resetTransaction = Transaction(animation: nil)
                withTransaction(resetTransaction) {
                    feedDragOffset = 0
                    isAnimatingFeedAdvance = false
                }
            }
            return
        }

        withAnimation(.easeOut(duration: 0.12)) {
            feedDragOffset = -min(max(viewportHeight * 0.04, 20), 44)
        }

        service.requestNextImage(in: scope)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.9, blendDuration: 0.08)) {
                feedDragOffset = 0
            }
        }
    }

    private func retreatFeed(in scope: ImageSelectionScope, viewportHeight: CGFloat) {
        guard !isAnimatingFeedAdvance else { return }

        isAnimatingFeedAdvance = true
        withAnimation(.timingCurve(0.22, 0.92, 0.28, 1, duration: 0.22)) {
            feedDragOffset = viewportHeight
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            service.requestPreviousImage(in: scope)
            let resetTransaction = Transaction(animation: nil)
            withTransaction(resetTransaction) {
                feedDragOffset = 0
                isAnimatingFeedAdvance = false
            }
        }
    }

    private func viewerInfoChip(_ label: String, tint: Color) -> some View {
        Text(label)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.88))
            )
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

private struct ZoomableImageSurface: UIViewRepresentable {
    let image: UIImage
    let assetID: UUID
    let isSwipeEnabled: Bool
    let onSwipeChanged: (CGFloat) -> Void
    let onSwipeEnded: (CGFloat, CGFloat) -> Void
    @Binding var zoomScale: CGFloat
    @Binding var minimumZoomScale: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> ZoomableImageSurfaceView {
        let view = ZoomableImageSurfaceView()
        view.scrollView.delegate = context.coordinator
        context.coordinator.surfaceView = view
        return view
    }

    func updateUIView(_ uiView: ZoomableImageSurfaceView, context: Context) {
        context.coordinator.parent = self
        uiView.isSwipeEnabled = isSwipeEnabled
        uiView.onSwipeChanged = onSwipeChanged
        uiView.onSwipeEnded = onSwipeEnded
        uiView.display(image: image, assetID: assetID)
        uiView.updateInteractionMode()
        context.coordinator.publishZoomState(from: uiView.scrollView)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: ZoomableImageSurface
        weak var surfaceView: ZoomableImageSurfaceView?

        init(parent: ZoomableImageSurface) {
            self.parent = parent
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            surfaceView?.imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            surfaceView?.centerImageIfNeeded()
            surfaceView?.updateInteractionMode()
            publishZoomState(from: scrollView)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            publishZoomState(from: scrollView)
        }

        func publishZoomState(from scrollView: UIScrollView) {
            let currentZoomScale = scrollView.zoomScale
            let currentMinimumZoomScale = scrollView.minimumZoomScale

            if abs(parent.zoomScale - currentZoomScale) < 0.0001,
               abs(parent.minimumZoomScale - currentMinimumZoomScale) < 0.0001 {
                return
            }

            DispatchQueue.main.async {
                self.parent.zoomScale = currentZoomScale
                self.parent.minimumZoomScale = currentMinimumZoomScale
            }
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

private final class ZoomableImageSurfaceView: UIView, UIGestureRecognizerDelegate {
    let scrollView = UIScrollView()
    let imageView = UIImageView()

    var isSwipeEnabled = false
    var onSwipeChanged: ((CGFloat) -> Void)?
    var onSwipeEnded: ((CGFloat, CGFloat) -> Void)?

    private var currentAssetID: UUID?
    private var currentImageSize: CGSize = .zero
    private var needsZoomReset = false
    private lazy var swipePanGestureRecognizer: UIPanGestureRecognizer = {
        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handleSwipePan(_:)))
        recognizer.delegate = self
        recognizer.cancelsTouchesInView = true
        recognizer.minimumNumberOfTouches = 1
        recognizer.maximumNumberOfTouches = 1
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

        imageView.backgroundColor = .clear
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = false

        addSubview(scrollView)
        scrollView.addSubview(imageView)
        scrollView.addGestureRecognizer(swipePanGestureRecognizer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        updateZoomScales(resetZoom: false)
    }

    func display(image: UIImage, assetID: UUID) {
        let isNewAsset = currentAssetID != assetID
        currentAssetID = assetID

        if isNewAsset {
            imageView.image = image
            currentImageSize = CGSize(
                width: max(image.size.width, 1),
                height: max(image.size.height, 1)
            )
            imageView.frame = CGRect(origin: .zero, size: currentImageSize)
            scrollView.contentSize = currentImageSize
            scrollView.contentInset = .zero
            scrollView.contentOffset = .zero
            needsZoomReset = true
        }

        updateZoomScales(resetZoom: isNewAsset)
        updateInteractionMode()
    }

    func centerImageIfNeeded() {
        let scaledContentWidth = imageView.frame.width * scrollView.zoomScale
        let scaledContentHeight = imageView.frame.height * scrollView.zoomScale
        let horizontalInset = max((bounds.width - scaledContentWidth) * 0.5, 0)
        let verticalInset = max((bounds.height - scaledContentHeight) * 0.5, 0)

        scrollView.contentInset = UIEdgeInsets(
            top: verticalInset,
            left: horizontalInset,
            bottom: verticalInset,
            right: horizontalInset
        )
    }

    private func updateZoomScales(resetZoom: Bool) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        guard currentImageSize.width > 0, currentImageSize.height > 0 else { return }

        let widthScale = bounds.width / currentImageSize.width
        let heightScale = bounds.height / currentImageSize.height
        let fitScale = min(widthScale, heightScale)

        // Keep smaller assets at native size, but fit larger ones on screen without cropping.
        let minimumScale = min(fitScale, 1)
        let maximumScale = max(minimumScale * 8, 4)
        let currentScale = scrollView.zoomScale == 0 ? minimumScale : scrollView.zoomScale
        let clampedScale = min(max(currentScale, minimumScale), maximumScale)

        scrollView.minimumZoomScale = minimumScale
        scrollView.maximumZoomScale = maximumScale

        let shouldResetZoom = resetZoom || needsZoomReset
        let targetScale = shouldResetZoom ? minimumScale : clampedScale
        if abs(scrollView.zoomScale - targetScale) > 0.0001 {
            scrollView.zoomScale = targetScale
        }
        if shouldResetZoom {
            needsZoomReset = false
        }

        centerImageIfNeeded()
        updateInteractionMode()
    }

    func updateInteractionMode() {
        let shouldOwnFeedSwipe = isSwipeEnabled && scrollView.zoomScale <= (scrollView.minimumZoomScale + 0.01)

        if scrollView.panGestureRecognizer.isEnabled == shouldOwnFeedSwipe {
            scrollView.panGestureRecognizer.isEnabled = !shouldOwnFeedSwipe
        }

        if swipePanGestureRecognizer.isEnabled != shouldOwnFeedSwipe {
            swipePanGestureRecognizer.isEnabled = shouldOwnFeedSwipe
        }
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
}

private struct SelectedUploadFile: Transferable {
    let filename: String
    let fileURL: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
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
}

private struct ViewerModeSwitcher: View {
    @Binding var selectedMode: ViewerScreenMode

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ViewerScreenMode.allCases) { mode in
                Button {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.84)) {
                        selectedMode = mode
                    }
                } label: {
                    Label(mode.rawValue, systemImage: mode.systemImage)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(selectedMode == mode ? Color.black : .white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            Capsule(style: .continuous)
                                .fill(selectedMode == mode ? .white : .white.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
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
