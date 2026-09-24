import SwiftUI

struct AppDetailView: View {
    let entryID: UUID
    @ObservedObject private var library = AppLibraryStore.shared
    @State private var showingSigningSheet = false
    @State private var showingInspector = false
    @State private var showingRename = false
    @State private var showingShareSheet = false
    @State private var showingInstall = false
    @State private var inspectionError: String?
    @Environment(\.dismiss) private var dismiss

    private var entry: AppEntry? {
        library.apps.first { $0.id == entryID }
    }

    var body: some View {
        Group {
            if let entry {
                content(for: entry)
            } else {
                Text("This app was removed.")
                    .foregroundStyle(SIColor.textSecondary)
            }
        }
        .siScreen()
        .navigationTitle(entry?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func content(for entry: AppEntry) -> some View {
        List {
            Section {
                VStack(spacing: SISpacing.md) {
                    HStack(spacing: SISpacing.md) {
                        iconView(for: entry)
                            .frame(width: 60, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: SIRadius.md, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.name).font(SIFont.title)
                            Text(entry.bundleIdentifier).font(SIFont.caption).foregroundStyle(SIColor.textSecondary)
                            Text("\(entry.displayVersion) · \(entry.displaySize)").font(SIFont.caption).foregroundStyle(SIColor.textSecondary)
                        }
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: SISpacing.sm) {
                        Button(entry.isSigned ? LocalizedStringKey("Re-sign") : LocalizedStringKey("Sign")) {
                            showingSigningSheet = true
                        }
                        .buttonStyle(.siPrimaryWide)
                        if entry.isSigned {
                            Button("Install") {
                                showingInstall = true
                            }
                            .buttonStyle(.siSecondaryWide)
                        }
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: SISpacing.sm, leading: 0, bottom: SISpacing.sm, trailing: 0))
            }

            Section {
                Button {
                    showingShareSheet = true
                } label: {
                    Label("Export IPA", systemImage: "square.and.arrow.up")
                }

                Button {
                    inspect(entry)
                } label: {
                    Label("Inspect", systemImage: "magnifyingglass")
                }
            } footer: {
                if entry.isSigned {
                    Text("Export IPA works every time — open it with AltStore, Sideloadly, or TrollStore. Direct on-device install depends on your iOS version and network, so it doesn't always succeed.")
                }
            }

            Section {
                Button {
                    showingRename = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    library.remove(entry)
                    dismiss()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }

            if entry.isSigned, let signedAt = entry.signedAt {
                Section("Signing Info") {
                    LabeledContent("Signed", value: signedAt.formatted(date: .abbreviated, time: .shortened))
                    if let certificate = CertificateStore.shared.certificate(withID: entry.certificateID) {
                        LabeledContent("Certificate", value: certificate.name)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .sheet(isPresented: $showingSigningSheet) {
            SigningSheetView(entryID: entry.id) {
                showingInstall = true
            }
        }
        .sheet(isPresented: $showingInspector) {
            if let report = inspectionReport {
                InspectorReportView(report: report)
            }
        }
        .sheet(isPresented: $showingRename) {
            NameInputSheet(title: String(localized: "Rename App"), placeholder: String(localized: "Name"), text: entry.name, confirmTitle: String(localized: "Save")) { newName in
                library.rename(entry, to: newName)
            }
        }
        .sheet(isPresented: $showingShareSheet) {
            ShareSheet(items: [library.ipaURL(for: entry)])
        }
        .overlay(alignment: .bottom) {
            if showingInstall {
                InstallStatusPill(entryID: entry.id) {
                    showingInstall = false
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showingInstall)
        .alert("Inspection Failed", isPresented: Binding(get: { inspectionError != nil }, set: { if !$0 { inspectionError = nil } })) {
            Button("OK") { inspectionError = nil }
        } message: {
            Text(inspectionError ?? "")
        }
    }

    @State private var inspectionReport: InspectionReport?

    private func inspect(_ entry: AppEntry) {
        do {
            inspectionReport = try InspectorService.inspect(ipaURL: library.ipaURL(for: entry))
            showingInspector = true
        } catch {
            inspectionError = error.localizedDescription
        }
    }

    @ViewBuilder
    private func iconView(for entry: AppEntry) -> some View {
        if let iconURL = library.iconURL(for: entry), let uiImage = UIImage(contentsOfFile: iconURL.path) {
            Image(uiImage: uiImage).resizable().scaledToFill()
        } else {
            RoundedRectangle(cornerRadius: SIRadius.md, style: .continuous)
                .fill(SIColor.surfaceElevated)
                .overlay(Image(systemName: "app.dashed").foregroundStyle(SIColor.textSecondary))
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
