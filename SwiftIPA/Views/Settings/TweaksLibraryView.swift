import SwiftUI
import UniformTypeIdentifiers

struct TweaksLibraryView: View {
    @ObservedObject private var dylibStore = DylibLibraryStore.shared
    @State private var showingPicker = false
    @State private var errorMessage: String?
    @State private var isImporting = false
    @State private var renaming: InjectedDylib?

    var body: some View {
        Group {
            if isImporting {
                ProgressView("Importing…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if dylibStore.dylibs.isEmpty {
                emptyState
            } else {
                tweaksList
            }
        }
        .siScreen()
        .navigationTitle("Tweak Library")
        .toolbar { tweaksToolbar }
        .sheet(isPresented: $showingPicker) { tweaksPicker }
        .sheet(item: $renaming) { dylib in
            NameInputSheet(title: String(localized: "Rename Tweak"), placeholder: String(localized: "Name"), text: dylib.displayName, confirmTitle: String(localized: "Save")) { name in
                dylibStore.rename(dylib, to: name)
            }
        }
        .alert("Import Failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var emptyState: some View {
        SIEmptyState(
            systemImage: "puzzlepiece.extension",
            title: "No tweaks yet",
            message: "Import a .dylib or .deb file to inject it into apps you sign."
        ) {
            Button("Import Tweak") { showingPicker = true }
                .buttonStyle(.siPrimary)
        }
    }

    private var tweaksList: some View {
        List {
            Section {
                ForEach(dylibStore.dylibs) { dylib in
                    TweakRow(dylib: dylib, analysis: dylibStore.analyses[dylib.id], hasProvider: dylibStore.substrateProvider != nil)
                        .contextMenu { contextMenu(for: dylib) }
                        .swipeActions(edge: .leading) {
                            Button {
                                renaming = dylib
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                        }
                }
                .onDelete { offsets in
                    for index in offsets { dylibStore.remove(dylibStore.dylibs[index]) }
                }
            } footer: {
                Text("Tweaks from a .deb that hook with CydiaSubstrate need ElleKit. Import ElleKit's .deb once and SwiftIPA injects it automatically whenever a tweak needs it. Long-press a tweak for more options.")
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func contextMenu(for dylib: InjectedDylib) -> some View {
        Button {
            dylibStore.setSubstrateProvider(dylib, enabled: !dylib.isSubstrateProvider)
        } label: {
            if dylib.isSubstrateProvider {
                Label("Stop Using as Substrate", systemImage: "xmark.circle")
            } else {
                Label("Use as Substrate (ElleKit)", systemImage: "link")
            }
        }
        Button {
            renaming = dylib
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        Button(role: .destructive) {
            dylibStore.remove(dylib)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    @ToolbarContentBuilder
    private var tweaksToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                showingPicker = true
            } label: {
                Image(systemName: "plus")
            }
        }
    }

    private var tweaksPicker: some View {
        DocumentPickerView(
            contentTypes: [.data, .item],
            allowsMultipleSelection: true
        ) { urls in
            guard !urls.isEmpty else { return }
            isImporting = true
            Task {
                var firstError: String?
                for url in urls {
                    do {
                        _ = try await dylibStore.importFile(at: url)
                    } catch {
                        if firstError == nil { firstError = error.localizedDescription }
                    }
                }
                await MainActor.run {
                    isImporting = false
                    errorMessage = firstError
                }
            }
        }
    }
}

struct TweakRow: View {
    let dylib: InjectedDylib
    let analysis: TweakAnalysis?
    let hasProvider: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(dylib.displayName)
                    .font(SIFont.headline)
                    .foregroundStyle(SIColor.textPrimary)
                if dylib.isSubstrateProvider {
                    StatusBadge(text: String(localized: "Substrate"), color: SIColor.accent)
                }
                if dylib.isDebPackage {
                    StatusBadge(text: "deb", color: SIColor.textSecondary)
                }
            }
            Text(dylib.displaySize)
                .font(SIFont.caption)
                .foregroundStyle(SIColor.textSecondary)
            if let analysis, analysis.needsSubstrate, !hasProvider {
                Text("Needs ElleKit – import its .deb first")
                    .font(SIFont.caption)
                    .foregroundStyle(SIColor.warning)
            }
            if let analysis, !analysis.jailbreakOnlyLibraries.isEmpty {
                Text("May not load without: \(analysis.jailbreakOnlyLibraries.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))")
                    .font(SIFont.caption)
                    .foregroundStyle(SIColor.textSecondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}
