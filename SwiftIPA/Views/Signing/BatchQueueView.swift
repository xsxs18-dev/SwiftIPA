import SwiftUI

struct BatchQueueView: View {
    let entryIDs: [UUID]

    @ObservedObject private var library = AppLibraryStore.shared
    @ObservedObject private var certificateStore = CertificateStore.shared
    @ObservedObject private var presetStore = PresetStore.shared

    @State private var certificateID: UUID?
    @State private var presetID: UUID?
    @State private var jobs: [SigningJob] = []
    @State private var isRunning = false
    @State private var hasStarted = false

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if !hasStarted {
                    Section("Certificate") {
                        Picker("Certificate", selection: $certificateID) {
                            ForEach(certificateStore.certificates) { certificate in
                                Text(certificate.name).tag(UUID?.some(certificate.id))
                            }
                        }
                    }
                    Section("Preset") {
                        Picker("Options", selection: $presetID) {
                            Text("Keep original names and IDs").tag(UUID?.none)
                            ForEach(presetStore.presets) { preset in
                                Text(preset.name).tag(UUID?.some(preset.id))
                            }
                        }
                    }
                    Section {
                        Text("\(entryIDs.count) app(s) will sign in parallel across your device's CPU cores. Apps already cached for this certificate finish instantly.")
                            .font(SIFont.caption)
                            .foregroundStyle(SIColor.textSecondary)
                    }
                } else {
                    Section("Progress") {
                        ForEach(jobs) { job in
                            BatchJobRow(job: job)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(.easeOut(duration: 0.3), value: hasStarted)
            .siScreen()
            .presentationDragIndicator(.visible)
            .navigationTitle("Batch Sign")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(hasStarted ? "Close" : "Cancel") { dismiss() }
                }
                if !hasStarted {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Start") { start() }
                            .disabled(certificateID == nil)
                    }
                }
            }
            .onAppear {
                certificateID = certificateStore.defaultCertificateID ?? certificateStore.certificates.first?.id
            }
        }
    }

    private func start() {
        guard let certificateID else { return }
        // Without a preset, use the default signing options from Settings like a single sign does.
        let options = presetID.flatMap { id in presetStore.presets.first { $0.id == id }?.options }
            ?? DefaultSigningOptionsStore.shared.options

        jobs = entryIDs.compactMap { id -> SigningJob? in
            guard let entry = library.apps.first(where: { $0.id == id }) else { return nil }
            var entryOptions = options
            if entryOptions.displayName.isEmpty { entryOptions.displayName = entry.name }
            if entryOptions.version.isEmpty { entryOptions.version = entry.version }
            if entryOptions.build.isEmpty { entryOptions.build = entry.build }
            return SigningJob(
                appEntryID: entry.id,
                sourceIPAURL: library.originalIPAURL(for: entry),
                displayName: entry.name,
                options: entryOptions,
                certificateID: certificateID
            )
        }

        hasStarted = true
        isRunning = true

        Task {
            await SigningEngine.shared.run(jobs: jobs)
            await MainActor.run { isRunning = false }
        }
    }
}

private struct BatchJobRow: View {
    @ObservedObject var job: SigningJob
    @State private var showingLog = false

    var body: some View {
        HStack {
            Text(job.displayName)
            Spacer()
            statusView
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if case .failed = job.status { showingLog = true }
        }
        .animation(.easeOut(duration: 0.2), value: job.status)
        .sheet(isPresented: $showingLog) {
            if case .failed(let message) = job.status {
                SigningLogView(title: job.displayName, message: message, log: job.log ?? "")
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch job.status {
        case .queued:
            Text("Queued").font(SIFont.caption).foregroundStyle(SIColor.textSecondary)
        case .extracting, .patching, .signing, .packaging:
            ProgressView()
        case .cached:
            Text("Cached").font(SIFont.caption).foregroundStyle(SIColor.accent)
        case .done(let seconds):
            StatusBadge(text: seconds < 0.05 ? String(localized: "Instant") : String(format: "%.1fs", seconds), color: SIColor.success)
        case .failed:
            HStack(spacing: 4) {
                StatusBadge(text: String(localized: "Failed"), color: SIColor.danger)
                // Tap the row for the message and zsign's log.
                Image(systemName: "info.circle").foregroundStyle(SIColor.danger)
            }
        }
    }
}
