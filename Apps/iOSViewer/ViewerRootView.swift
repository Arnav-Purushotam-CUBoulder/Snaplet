import SwiftUI
import CoreTransferable
import PhotosUI

struct ViewerRootView: View {
    @StateObject private var service: PeerViewerService
    @State private var dragOffset: CGFloat = 0
    @State private var selectedUploadItems: [PhotosPickerItem] = []

    init() {
        let cacheDirectory = (try? AppSupportPaths.viewerCacheDirectory()) ?? FileManager.default.temporaryDirectory
        _service = StateObject(wrappedValue: PeerViewerService(cacheDirectory: cacheDirectory))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
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

                VStack(spacing: 18) {
                    statusPanel
                        .padding(.top, 8)

                    Spacer(minLength: 0)

                    ViewerImageStage(
                        image: service.currentImage,
                        filename: service.currentFilename,
                        isLoading: service.isLoadingImage,
                        dragOffset: dragOffset
                    )
                    .frame(height: geometry.size.height * 0.62)
                    .padding(.horizontal, 18)
                    .gesture(swipeGesture)

                    Spacer(minLength: 0)

                    bottomPanel
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 24)
            }
        }
        .onAppear {
            service.start()
        }
        .onDisappear {
            service.stop()
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

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            statusTitleBlock
            reconnectButton

            HStack(spacing: 12) {
                statusPill(label: service.connectionStatus, tint: Color(red: 0.95, green: 0.55, blue: 0.24))
                statusPill(label: "\(service.libraryCount) indexed", tint: Color(red: 0.26, green: 0.63, blue: 0.49))
                if service.isPrefetching {
                    statusPill(label: "preloading", tint: Color(red: 0.21, green: 0.42, blue: 0.88))
                }
            }
        }
        .padding(20)
        .background(panelBackground)
    }

    private var statusTitleBlock: some View {
        HStack(spacing: 12) {
            Image("SnapletMark")
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text("Snaplet")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .layoutPriority(1)

                Text(service.hostName ?? "Looking for your Mac host")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
            }
        }
    }

    private var reconnectButton: some View {
        Button("Reconnect") {
            service.restartDiscovery()
        }
        .buttonStyle(.borderedProminent)
        .tint(Color(red: 0.89, green: 0.48, blue: 0.20))
    }

    private var bottomPanel: some View {
        let uploadButtonTitle = service.isUploadingImages ? "Uploading…" : "Upload"

        return VStack(alignment: .leading, spacing: 12) {
            if let errorMessage = service.errorMessage {
                Text(errorMessage)
                    .font(.headline)
                    .foregroundStyle(Color(red: 1.0, green: 0.78, blue: 0.72))
            }

            if let uploadStatusMessage = service.uploadStatusMessage {
                Text(uploadStatusMessage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(red: 0.81, green: 0.95, blue: 0.84))
            }

            Text(service.currentFilename ?? "Swipe down to request your first random image.")
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(2)

            Text("Pull down like a feed refresh. Each successful swipe asks the Mac host for a random indexed image and swaps it in.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.78))

            HStack(spacing: 12) {
                Button {
                    service.requestNextImage()
                } label: {
                    Text("Load Another")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.89, green: 0.48, blue: 0.20))

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
        .padding(20)
        .background(panelBackground)
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { value in
                if value.translation.height > 0 {
                    dragOffset = value.translation.height
                }
            }
            .onEnded { value in
                let shouldLoadNext = value.translation.height > 140 || value.predictedEndTranslation.height > 220

                withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) {
                    dragOffset = 0
                }

                if shouldLoadNext {
                    service.requestNextImage()
                }
            }
    }

    private func statusPill(label: String, tint: Color) -> some View {
        Text(label)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.86))
            )
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .fill(.white.opacity(0.1))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.22), radius: 24, x: 0, y: 18)
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

private struct ViewerImageStage: View {
    let image: SnapletPlatformImage?
    let filename: String?
    let isLoading: Bool
    let dragOffset: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 38, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            .black.opacity(0.62),
                            Color(red: 0.16, green: 0.10, blue: 0.10)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 38, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        Text(filename ?? "Current image")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .padding(14)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(.black.opacity(0.45))
                            )
                            .padding(18)
                    }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 48, weight: .regular))
                        .foregroundStyle(.white.opacity(0.88))

                    Text("No Image Yet")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)

                    Text("When the Mac host is connected, pull down to fetch a random image from the local library.")
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.78))
                        .padding(.horizontal, 24)
                }
            }

            if isLoading {
                ProgressView("Fetching from your Mac…")
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .padding(20)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(.black.opacity(0.5))
                    )
            }
        }
        .offset(y: dragOffset)
        .rotation3DEffect(
            .degrees(Double(dragOffset / 14)),
            axis: (x: 1, y: 0, z: 0),
            perspective: 0.7
        )
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: dragOffset)
        .shadow(color: .black.opacity(0.28), radius: 28, x: 0, y: 22)
        .overlay(alignment: .bottom) {
            if dragOffset > 8 {
                Text("Release to load the next random image")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        Capsule(style: .continuous)
                            .fill(.black.opacity(0.46))
                    )
                    .padding(.bottom, 18)
                    .transition(.opacity)
            }
        }
    }
}
