import SwiftUI
import UIKit

struct RootTabView: View {
    @State private var importMessage: String?

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
        .onAppear(perform: handleForeground)
        .onOpenURL { _ in handleForeground() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            handleForeground()
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

    private func handleForeground() {
        Task {
            await importPending()
        }
    }

    private func importPending() async {
        let pending = InboxStore.takePending()
        guard !pending.isEmpty else { return }

        var imported = 0
        for item in pending {
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(item.suggestedName)
            do {
                try? FileManager.default.removeItem(at: tempURL)
                try item.data.write(to: tempURL)
                _ = try await AppLibraryStore.shared.importIPA(at: tempURL, sourceName: String(localized: "Shared from another app"))
                imported += 1
            } catch {
                continue
            }
            try? FileManager.default.removeItem(at: tempURL)
        }

        if imported > 0 {
            importMessage = String(localized: "Brought in \(imported) app(s) shared from another app.")
        }
    }
}
