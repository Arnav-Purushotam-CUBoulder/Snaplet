import SwiftUI
import CoreTransferable
import PhotosUI

private enum ViewerScreenMode: String, CaseIterable, Identifiable {
    case menu = "Menu"
    case feed = "Feed"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .menu:
            "slider.horizontal.3"
        case .feed:
            "rectangle.stack.fill"
        }
    }
}

struct ViewerRootView: View {
    @StateObject private var service: PeerViewerService
    @State private var feedDragOffset: CGFloat = 0
    @State private var selectedUploadItems: [PhotosPickerItem] = []
    @State private var selectedScreen: ViewerScreenMode = .menu

    init() {
        let cacheDirectory = (try? AppSupportPaths.viewerCacheDirectory()) ?? FileManager.default.temporaryDirectory
        _service = StateObject(wrappedValue: PeerViewerService(cacheDirectory: cacheDirectory))
    }

    var body: some View {
        ZStack {
            appBackground

            Group {
                switch selectedScreen {
                case .menu:
                    menuScreen
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                case .feed:
                    feedScreen
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: selectedScreen)
        .safeAreaInset(edge: .top, spacing: 0) {
            ViewerModeSwitcher(selectedMode: $selectedScreen)
                .padding(.horizontal, 20)
                .padding(.top, 8)
        }
        .onAppear {
            service.start()
        }
        .onDisappear {
            service.stop()
        }
        .onChange(of: selectedScreen) { _, screen in
            guard screen == .feed, service.currentImage == nil, !service.isLoadingImage else { return }
            service.requestNextImage()
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
    }

    private var appBackground: some View {
        LinearGradient(
            colors: [
                Color(red: 0.06, green: 0.08, blue: 0.12),
                Color(red: 0.18, green: 0.12, blue: 0.10),
                Color(red: 0.44, green: 0.22, blue: 0.10)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    private var menuScreen: some View {
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

                            Text("Menu and feed are now separate. Use the switcher above to jump into the full-screen viewer.")
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

                ViewerMenuCard(title: "Actions", subtitle: "Jump into the viewer or send new lossless images to the Mac host.") {
                    VStack(spacing: 12) {
                        Button {
                            withAnimation(.spring(response: 0.38, dampingFraction: 0.84)) {
                                selectedScreen = .feed
                            }
                            if service.currentImage == nil {
                                service.requestNextImage()
                            }
                        } label: {
                            Label(service.currentImage == nil ? "Open Feed" : "Back to Feed", systemImage: "arrow.up.forward.app")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(red: 0.80, green: 0.38, blue: 0.15))

                        Button {
                            service.requestNextImage()
                            withAnimation(.spring(response: 0.38, dampingFraction: 0.84)) {
                                selectedScreen = .feed
                            }
                        } label: {
                            Label("Load Random Image", systemImage: "shuffle")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)

                        PhotosPicker(
                            selection: $selectedUploadItems,
                            maxSelectionCount: 20,
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
            .padding(.top, 20)
            .padding(.bottom, 28)
        }
    }

    private var feedScreen: some View {
        feedSurface
            .contentShape(Rectangle())
            .offset(y: feedDragOffset)
            .animation(.spring(response: 0.34, dampingFraction: 0.84), value: feedDragOffset)
            .gesture(feedSwipeGesture)
            .overlay(alignment: .bottom) {
                if feedDragOffset < -8 {
                    Text("Release to load the next random image")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            Capsule(style: .continuous)
                                .fill(.black.opacity(0.52))
                        )
                        .padding(.bottom, 120)
                }
            }
            .ignoresSafeArea()
    }

    private var feedSurface: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            if let image = service.currentImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .ignoresSafeArea()
            } else {
                VStack(spacing: 18) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 54, weight: .regular))
                        .foregroundStyle(.white.opacity(0.88))

                    Text("No Image Yet")
                        .font(.title.weight(.bold))
                        .foregroundStyle(.white)

                    Text("Switch to Feed and swipe up to pull a random image from your Mac host.")
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 28)

                    if !service.isLoadingImage {
                        Button {
                            service.requestNextImage()
                        } label: {
                            Label("Load First Image", systemImage: "arrow.up")
                                .font(.headline)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(red: 0.89, green: 0.48, blue: 0.20))
                    }
                }
                .padding(.top, 80)
            }

            LinearGradient(
                colors: [
                    .clear,
                    .black.opacity(0.16),
                    .black.opacity(0.72)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            if service.isLoadingImage {
                ProgressView("Fetching from your Mac…")
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 18)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(.black.opacity(0.56))
                    )
            }

            VStack(alignment: .leading, spacing: 14) {
                Spacer()

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        viewerInfoChip(service.connectionStatus, tint: Color(red: 0.95, green: 0.55, blue: 0.24))
                        viewerInfoChip("\(service.libraryCount) indexed", tint: Color(red: 0.26, green: 0.63, blue: 0.49))
                        if service.isPrefetching {
                            viewerInfoChip("preloading", tint: Color(red: 0.21, green: 0.42, blue: 0.88))
                        }
                    }
                }

                Text(service.currentFilename ?? "Swipe up to load a random image.")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                Text(service.hostName ?? "Looking for your Mac host")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.82))

                if let errorMessage = service.errorMessage {
                    Text(errorMessage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color(red: 1.0, green: 0.78, blue: 0.72))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.bottom, 34)
        }
    }

    private var feedSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 22)
            .onChanged { value in
                guard value.translation.height < 0 else { return }
                feedDragOffset = max(value.translation.height, -160)
            }
            .onEnded { value in
                let shouldLoadNext = value.translation.height < -110 || value.predictedEndTranslation.height < -200

                guard shouldLoadNext else {
                    withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) {
                        feedDragOffset = 0
                    }
                    return
                }

                withAnimation(.easeOut(duration: 0.16)) {
                    feedDragOffset = -140
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    service.requestNextImage()
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) {
                        feedDragOffset = 0
                    }
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

private struct SelectedUploadFile: Transferable {
    let filename: String
    let fileURL: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let sourceURL = received.file
            let fileExtension = sourceURL.pathExtension
            let filename = fileExtension.isEmpty
                ? "iphone-\(UUID().uuidString)"
                : "iphone-\(UUID().uuidString).\(fileExtension)"
            let destinationURL = FileManager.default.temporaryDirectory.appending(path: filename)

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
        HStack(spacing: 8) {
            ForEach(ViewerScreenMode.allCases) { mode in
                Button {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.84)) {
                        selectedMode = mode
                    }
                } label: {
                    Label(mode.rawValue, systemImage: mode.systemImage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(selectedMode == mode ? Color.black : .white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            Capsule(style: .continuous)
                                .fill(selectedMode == mode ? .white : .white.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 24, x: 0, y: 16)
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
