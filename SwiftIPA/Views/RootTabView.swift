import SwiftUI
import UIKit

struct RootTabView: View {
    @State private var importMessage: String?
    @State private var importError: String?
    @State private var importingURLs: Set<URL> = []

    var body: some View {
        TabView {
            NavigationStack {
                LibraryView()
            }
            .tabItem {
                Label("Library", systemImage: "square.stack.3d.up")
            }

            NavigationStack {
                SourcesView()
            }
            .tabItem {
                Label("Sources", systemImage: "tray.full")
            }

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
        }
        .tint(SIColor.accent)
        .onOpenURL { url in
            if url.isFileURL { importFile(url) }
        }
        .alert("Import Failed", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .alert("Imported from Share Sheet", isPresented: Binding(
            get: { importMessage != nil },
            set: { isPresented in if !isPresented { importMessage = nil } }
        ), presenting: importMessage) { _ in
            Button("OK") { importMessage = nil }
        } message: { message in
            Text(message)
        }
    }

    private func importFile(_ url: URL) {
        guard importingURLs.insert(url).inserted else { return }
        Task { @MainActor in
            defer { importingURLs.remove(url) }
            do {
                guard ["ipa", "tipa"].contains(url.pathExtension.lowercased()) else {
                    throw CocoaError(.fileReadUnsupportedScheme)
                }
                _ = try await AppLibraryStore.shared.importIPA(at: url, sourceName: String(localized: "Shared from another app"))
                importMessage = String(localized: "App imported into Library.")
            } catch {
                importError = error.localizedDescription
            }
        }
    }

}
