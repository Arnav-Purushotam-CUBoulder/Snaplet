import SwiftUI
import UniformTypeIdentifiers

struct HostDashboardView: View {
    @StateObject private var model: HostDashboardModel
    @State private var isImporting = false

    init() {
        do {
            let rootDirectory = try AppSupportPaths.hostRootDirectory()
            _model = StateObject(wrappedValue: HostDashboardModel(rootDirectory: rootDirectory, usingFallbackStorage: false))
        } catch {
            _model = StateObject(
                wrappedValue: HostDashboardModel(
                    storageRootDirectory: AppSupportPaths.expectedHostRootDirectory(),
                    configurationError: error
                )
            )
        }
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.98, green: 0.95, blue: 0.88),
                    Color(red: 0.93, green: 0.85, blue: 0.73),
                    Color(red: 0.85, green: 0.77, blue: 0.66)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    actionRow

                    if let feedback = model.importFeedback {
                        statusBanner(feedback, tint: .green)
                    }

                    if let errorMessage = model.errorMessage {
                        statusBanner(errorMessage, tint: .red)
                    }

                    metricsSection
                    contentSection
                    footerNote
                }
                .padding(28)
            }
        }
        .fontDesign(.rounded)
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.image, .movie, .video],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case let .success(urls):
                model.importAssets(from: urls)
            case let .failure(error):
                model.errorMessage = error.localizedDescription
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            Image("SnapletMark")
                .resizable()
                .scaledToFit()
                .frame(width: 76, height: 76)
                .padding(14)
                .background(cardBackground(tint: .white.opacity(0.42)))

            VStack(alignment: .leading, spacing: 10) {
                Text("Snaplet Host")
                    .font(.system(size: 38, weight: .bold, design: .rounded))

                Text("Mac-native dashboard and media server for the iPhone random viewer.")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                if let viewerDevice = model.metadata.viewerDevice {
                    Text("Viewer Device: \(viewerDevice.modelName)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color(red: 0.40, green: 0.24, blue: 0.14))
                }
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 16) {
            Button("Import Media…") {
                isImporting = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button("Reindex Library") {
                model.reindexLibrary()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button("Refresh") {
                model.refreshLibrary()
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Spacer(minLength: 24)

            VStack(alignment: .trailing, spacing: 4) {
                Text("Storage Root")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(model.storageRootDirectory.path)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(22)
        .background(cardBackground(tint: .white.opacity(0.4)))
    }

    private var metricsSection: some View {
        let columns = [
            GridItem(.flexible(), spacing: 18),
            GridItem(.flexible(), spacing: 18),
            GridItem(.flexible(), spacing: 18),
            GridItem(.flexible(), spacing: 18)
        ]

        return LazyVGrid(columns: columns, spacing: 18) {
            MetricCard(
                title: "Indexed Photos",
                value: "\(model.libraryStatus.photoCount)",
                subtitle: model.libraryStatus.latestAsset?.originalFilename ?? "Import or reindex your first media set",
                tint: Color(red: 0.72, green: 0.37, blue: 0.18)
            )

            MetricCard(
                title: "Indexed Videos",
                value: "\(model.libraryStatus.videoCount)",
                subtitle: "\(model.libraryStatus.favoriteVideoCount) favorite video\(model.libraryStatus.favoriteVideoCount == 1 ? "" : "s")",
                tint: Color(red: 0.20, green: 0.33, blue: 0.62)
            )

            if let hostService = model.hostService {
                HostConnectionCard(service: hostService)
                HostAdvertisingCard(service: hostService)
            } else {
                MetricCard(
                    title: "Connection",
                    value: "Offline",
                    subtitle: "Host service unavailable",
                    tint: .gray
                )

                MetricCard(
                    title: "Advertising",
                    value: "Stopped",
                    subtitle: "Host service unavailable",
                    tint: .gray
                )
            }
        }
    }

    private var contentSection: some View {
        HStack(alignment: .top, spacing: 20) {
            RecentMediaPanel(assets: model.libraryStatus.recentAssets)

            if let hostService = model.hostService {
                HostActivityPanel(service: hostService)
            } else {
                PlaceholderPanel(
                    title: "Activity",
                    message: "The host service could not be created, so there is no live session activity yet."
                )
            }
        }
    }

    private var footerNote: some View {
        Text("Transport uses MultipeerConnectivity for direct discovery and transfer between your Mac and iPhone. The host media store and SQLite index live on the Seagate Expansion Drive, with photos in `Photos/` and videos in `Videos/`. Apple may still choose infrastructure Wi-Fi, peer-to-peer Wi-Fi, or Bluetooth underneath the session.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    private func statusBanner(_ message: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(tint)
                .frame(width: 10, height: 10)

            Text(message)
                .font(.headline)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground(tint: tint.opacity(0.18)))
    }

    private func cardBackground(tint: Color) -> some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(tint)
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(.white.opacity(0.35), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 22, x: 0, y: 18)
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let subtitle: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)

            Text(subtitle)
                .font(.headline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(22)
        .frame(maxWidth: .infinity, minHeight: 164, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(tint.opacity(0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(.white.opacity(0.35), lineWidth: 1)
                )
        )
    }
}

private struct HostConnectionCard: View {
    @ObservedObject var service: PeerHostService

    var body: some View {
        MetricCard(
            title: "Connected Viewers",
            value: "\(service.connectedPeerNames.count)",
            subtitle: service.connectedPeerNames.isEmpty ? "Waiting for iPhone" : service.connectedPeerNames.joined(separator: ", "),
            tint: Color(red: 0.13, green: 0.44, blue: 0.36)
        )
    }
}

private struct HostAdvertisingCard: View {
    @ObservedObject var service: PeerHostService

    var body: some View {
        MetricCard(
            title: "Advertising",
            value: service.isAdvertising ? "Live" : "Stopped",
            subtitle: service.connectionStatus,
            tint: Color(red: 0.08, green: 0.27, blue: 0.55)
        )
    }
}

private struct RecentMediaPanel: View {
    let assets: [ImageAsset]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Recent Imports")
                .font(.title2.weight(.bold))

            if assets.isEmpty {
                PlaceholderPanel(
                    title: "No Media Yet",
                    message: "Import photos or videos, or run a reindex to pull the full library into SQLite."
                )
            } else {
                VStack(spacing: 12) {
                    ForEach(assets) { asset in
                        HStack(alignment: .top, spacing: 14) {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(red: 0.27, green: 0.18, blue: 0.14))
                                .frame(width: 56, height: 56)
                                .overlay(
                                    Image(systemName: asset.mediaType.systemImage)
                                        .font(.title3)
                                        .foregroundStyle(.white.opacity(0.9))
                                )

                            VStack(alignment: .leading, spacing: 4) {
                                Text(asset.originalFilename)
                                    .font(.headline)
                                    .lineLimit(1)

                                Text(ByteCountFormatter.string(fromByteCount: asset.byteSize, countStyle: .file))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)

                                Text(asset.mediaType == .photo ? "Photo" : "Video")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(asset.mediaType == .photo ? Color(red: 0.54, green: 0.28, blue: 0.15) : Color(red: 0.18, green: 0.34, blue: 0.64))

                                Text(asset.importedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 12)

                            if asset.isFavorite {
                                Image(systemName: "star.fill")
                                    .font(.headline)
                                    .foregroundStyle(Color(red: 0.83, green: 0.62, blue: 0.15))
                            }
                        }
                        .padding(16)
                        .background(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(.white.opacity(0.45))
                        )
                    }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.white.opacity(0.38))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(.white.opacity(0.35), lineWidth: 1)
                )
        )
    }
}

private struct HostActivityPanel: View {
    @ObservedObject var service: PeerHostService

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Live Activity")
                .font(.title2.weight(.bold))

            if service.activityLog.isEmpty {
                PlaceholderPanel(
                    title: "Quiet Session",
                    message: "Once the iPhone connects and starts requesting media, transfers and state changes will appear here."
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(service.activityLog, id: \.self) { entry in
                            Text(entry)
                                .font(.body.monospaced())
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(.white.opacity(0.48))
                                )
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 420, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.white.opacity(0.38))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(.white.opacity(0.35), lineWidth: 1)
                )
        )
    }
}

private struct PlaceholderPanel: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)

            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .leading)
    }
}
