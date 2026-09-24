import SwiftUI

private enum ResetAction: Identifiable, Equatable {
    case signedApps
    case importedApps
    case certificates
    case everything

    var id: Int {
        switch self {
        case .signedApps: return 0
        case .importedApps: return 1
        case .certificates: return 2
        case .everything: return 3
        }
    }

    var title: String {
        switch self {
        case .signedApps: return String(localized: "Remove all signed apps?")
        case .importedApps: return String(localized: "Remove all imported apps?")
        case .certificates: return String(localized: "Remove all certificates?")
        case .everything: return String(localized: "Reset SwiftIPA completely?")
        }
    }

    var message: String {
        switch self {
        case .signedApps: return String(localized: "This deletes every signed app from your library. Their original imported IPAs are removed too.")
        case .importedApps: return String(localized: "This deletes every app in your library that hasn't been signed yet. Signed apps are left alone.")
        case .certificates: return String(localized: "This deletes every certificate, its saved password, and its expiry tracking.")
        case .everything: return String(localized: "This deletes your entire library, all certificates, tweaks, presets, sources, and the signing cache, and resets every setting. There's no undo.")
        }
    }

    var confirmTitle: String {
        self == .everything ? String(localized: "Reset Everything") : String(localized: "Remove")
    }
}

struct SettingsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var certificateStore = CertificateStore.shared
    @ObservedObject private var dylibStore = DylibLibraryStore.shared
    @State private var cacheSize: Int64 = SigningCache.shared.totalSize
    @State private var updateResult: UpdateCheckResult?
    @State private var isCheckingUpdate = false
    @State private var updateError: String?

    var body: some View {
        List {
            Section {
                NavigationLink {
                    CertificatesView()
                } label: {
                    LabeledContent("Certificates", value: "\(certificateStore.certificates.count)")
                }
                NavigationLink {
                    TweaksLibraryView()
                } label: {
                    LabeledContent("Tweak Library", value: "\(dylibStore.dylibs.count)")
                }
                NavigationLink("Signing Presets") { PresetsView() }
                NavigationLink("Default Signing Options") { DefaultSigningOptionsView() }
            } header: {
                Text("Signing")
            }

            Section {
                NavigationLink {
                    ThemePickerView()
                } label: {
                    HStack {
                        Text("Theme")
                        Spacer()
                        Circle()
                            .fill(SIColor.accent)
                            .frame(width: 10, height: 10)
                        Text(themeManager.current.id.displayName)
                            .foregroundStyle(SIColor.textSecondary)
                    }
                }
            } header: {
                Text("Appearance")
            }

            Section {
                LabeledContent("Instant-Resign Cache", value: ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file))
                Button("Clear Cache", role: .destructive) {
                    SigningCache.shared.clear()
                    cacheSize = 0
                }
            } header: {
                Text("Cache")
            }

            Section {
                NavigationLink("Bugs & Issues") { BugReportView() }
                NavigationLink("Changelog") { ChangelogView() }
                Link("Source on GitHub", destination: BugReportView.repositoryURL)
            } header: {
                Text("Support")
            }

            Section {
                LabeledContent("Version", value: versionString)
                Button {
                    checkForUpdate()
                } label: {
                    if isCheckingUpdate {
                        ProgressView()
                    } else {
                        Text("Check for Updates")
                    }
                }
                if let updateResult {
                    if updateResult.isUpdateAvailable {
                        Link("Update to \(updateResult.latestVersion) available", destination: updateResult.releaseURL)
                    } else {
                        Text("You're up to date.").foregroundStyle(SIColor.textSecondary)
                    }
                }
                if let updateError {
                    Text(updateError).foregroundStyle(SIColor.danger).font(SIFont.caption)
                }
            } header: {
                Text("About")
            }

            Section {
                NavigationLink("Storage & Reset") { StorageResetView() }
            }
        }
        .listStyle(.insetGrouped)
        .siScreen()
        .navigationTitle("Settings")
        .onAppear { cacheSize = SigningCache.shared.totalSize }
    }

    private var versionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }

    private func checkForUpdate() {
        isCheckingUpdate = true
        updateError = nil
        Task {
            do {
                let result = try await UpdateChecker.shared.checkForUpdate()
                await MainActor.run {
                    updateResult = result
                    isCheckingUpdate = false
                }
            } catch {
                await MainActor.run {
                    updateError = error.localizedDescription
                    isCheckingUpdate = false
                }
            }
        }
    }
}

private struct ThemePickerView: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    var body: some View {
        List {
            ForEach(SIThemeID.allCases) { id in
                Button {
                    themeManager.select(id)
                } label: {
                    HStack {
                        Circle()
                            .fill(SITheme.theme(for: id).accent)
                            .frame(width: 14, height: 14)
                        Text(id.displayName)
                            .foregroundStyle(SIColor.textPrimary)
                        Spacer()
                        if themeManager.current.id == id {
                            Image(systemName: "checkmark").foregroundStyle(SIColor.accent)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .siScreen()
        .navigationTitle("Theme")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct StorageResetView: View {
    @State private var pendingReset: ResetAction?

    var body: some View {
        List {
            Section {
                Button {
                    openAppFolder()
                } label: {
                    Label("View App Folder", systemImage: "folder")
                }
            } footer: {
                Text("Opens SwiftIPA's Documents folder in the Files app — imported and signed IPAs, certificates, tweaks, and presets all live there.")
            }

            Section {
                Button("Remove All Signed Apps", role: .destructive) { pendingReset = .signedApps }
                Button("Remove All Imported Apps", role: .destructive) { pendingReset = .importedApps }
                Button("Remove All Certificates", role: .destructive) { pendingReset = .certificates }
                Button("Reset Everything", role: .destructive) { pendingReset = .everything }
            } header: {
                Text("Reset")
            } footer: {
                Text("These remove data from this device only and can't be undone.")
            }
        }
        .listStyle(.insetGrouped)
        .siScreen()
        .navigationTitle("Storage & Reset")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            pendingReset?.title ?? "",
            isPresented: Binding(get: { pendingReset != nil }, set: { if !$0 { pendingReset = nil } }),
            titleVisibility: .visible
        ) {
            if let pendingReset {
                Button(pendingReset.confirmTitle, role: .destructive) {
                    performReset(pendingReset)
                }
            }
        } message: {
            if let pendingReset {
                Text(pendingReset.message)
            }
        }
    }

    private func openAppFolder() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let url = URL(string: "shareddocuments://" + documents.path) else { return }
        UIApplication.shared.open(url)
    }

    private func performReset(_ action: ResetAction) {
        switch action {
        case .signedApps:
            AppLibraryStore.shared.removeAll { $0.isSigned }
        case .importedApps:
            AppLibraryStore.shared.removeAll { !$0.isSigned }
        case .certificates:
            CertificateStore.shared.removeAllCertificates()
        case .everything:
            AppLibraryStore.shared.removeAll { _ in true }
            CertificateStore.shared.removeAllCertificates()
            DylibLibraryStore.shared.removeAll()
            PresetStore.shared.removeAll()
            SourceStore.shared.removeAll()
            DefaultSigningOptionsStore.shared.resetToDefaults()
            SigningCache.shared.clear()
        }
    }
}
