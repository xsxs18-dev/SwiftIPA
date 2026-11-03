import SwiftUI

struct SourceDetailView: View {
    let sourceID: UUID

    @ObservedObject private var sourceStore = SourceStore.shared
    @State private var downloadingID: String?
    @State private var progress: Double?
    @State private var downloadedBytes: Int64 = 0
    @State private var errorMessage: String?
    @State private var signEntryID: UUID?

    private var source: RepositorySource? {
        sourceStore.sources.first { $0.id == sourceID }
    }

    var body: some View {
        Group {
            if let source {
                List(sourceStore.apps(for: source)) { app in
                    RepositoryAppRow(
                        app: app,
                        isDownloading: downloadingID == app.id,
                        progress: progress,
                        downloadedBytes: downloadedBytes,
                        onDownload: { download(app) }
                    )
                }
                .listStyle(.plain)
                .refreshable {
                    await sourceStore.refresh(source)
                }
            }
        }
        .siScreen()
        .navigationTitle(source?.name ?? "Source")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Download Failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(isPresented: Binding(get: { signEntryID != nil }, set: { if !$0 { signEntryID = nil } })) {
            if let signEntryID {
                SigningSheetView(entryID: signEntryID)
            }
        }
    }

    private func download(_ app: RepositoryApp) {
        guard let version = app.latest else { return }
        downloadingID = app.id
        progress = 0
        downloadedBytes = 0
        Task {
            do {
                let url = try await RepositoryService.download(version) { fraction, bytesWritten in
                    Task { @MainActor in
                        progress = fraction
                        downloadedBytes = bytesWritten
                    }
                }
                // Also when the import fails, otherwise the download stays in tmp.
                defer { try? FileManager.default.removeItem(at: url) }
                let entry = try await AppLibraryStore.shared.importIPA(at: url, sourceName: source?.name)
                await MainActor.run {
                    downloadingID = nil
                    signEntryID = entry.id
                }
            } catch {
                await MainActor.run {
                    downloadingID = nil
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

private struct RepositoryAppRow: View {
    let app: RepositoryApp
    let isDownloading: Bool
    let progress: Double?
    let downloadedBytes: Int64
    let onDownload: () -> Void

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    var body: some View {
        HStack(spacing: SISpacing.md) {
            AsyncImage(url: app.iconURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                RoundedRectangle(cornerRadius: SIRadius.sm, style: .continuous).fill(SIColor.surfaceElevated)
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: SIRadius.sm, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(SIFont.headline)
                Text(app.latest?.version ?? "").font(SIFont.caption).foregroundStyle(SIColor.textSecondary)
            }

            Spacer()

            if isDownloading {
                if let progress {
                    ProgressView(value: progress)
                        .frame(width: 60)
                } else {
                    VStack(alignment: .trailing, spacing: 2) {
                        ProgressView()
                        Text(Self.byteFormatter.string(fromByteCount: downloadedBytes))
                            .font(SIFont.caption)
                            .foregroundStyle(SIColor.textSecondary)
                    }
                }
            } else {
                Button("Get") { onDownload() }
                    .buttonStyle(.siSecondary)
            }
        }
        .padding(.vertical, 4)
    }
}
