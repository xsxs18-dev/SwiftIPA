import SwiftUI

struct SourcesView: View {
    @ObservedObject private var sourceStore = SourceStore.shared
    @State private var showingAddSheet = false

    var body: some View {
        Group {
            if sourceStore.sources.isEmpty {
                emptyState
            } else {
                sourceList
            }
        }
        .siScreen()
        .navigationTitle("Sources")
        .navigationDestination(for: RepositorySource.self) { source in
            SourceDetailView(sourceID: source.id)
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            AddSourceSheet()
        }
    }

    private var sourceList: some View {
        List {
            ForEach(sourceStore.sources) { source in
                NavigationLink(value: source) {
                    SourceRow(source: source)
                }
                .buttonStyle(.siPressableCard)
            }
            .onDelete { offsets in
                for index in offsets { sourceStore.removeSource(sourceStore.sources[index]) }
            }
            .listRowInsets(EdgeInsets(top: SISpacing.xs, leading: SISpacing.md, bottom: SISpacing.xs, trailing: SISpacing.md))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
    }

    private var emptyState: some View {
        SIEmptyState(
            systemImage: "tray",
            title: "No sources yet",
            message: "Add an AltStore or ESign-compatible repo URL to browse and sign apps straight from it."
        ) {
            Button("Add Source") { showingAddSheet = true }
                .buttonStyle(.siPrimary)
        }
    }
}

struct SourceRow: View {
    let source: RepositorySource

    var body: some View {
        HStack(spacing: SISpacing.md) {
            AsyncImage(url: source.iconURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                RoundedRectangle(cornerRadius: SIRadius.sm, style: .continuous).fill(SIColor.surfaceElevated)
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: SIRadius.sm, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(source.name).font(SIFont.headline)
                Text(source.subtitle ?? source.url.host ?? "")
                    .font(SIFont.caption)
                    .foregroundStyle(SIColor.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Text("\(source.appCount)")
                .font(SIFont.caption)
                .foregroundStyle(SIColor.textSecondary)
        }
        .padding(SISpacing.sm + 2)
        .siCard()
    }
}
