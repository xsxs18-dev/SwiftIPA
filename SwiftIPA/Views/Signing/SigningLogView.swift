import SwiftUI

/// zsign's output after a failed sign, to copy into a bug report.
struct SigningLogView: View {
    let title: String
    let message: String
    let log: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    private var report: String {
        "\(title)\n\(message)\n\n\(log)"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SISpacing.md) {
                    Text(message)
                        .font(SIFont.headline)
                        .foregroundStyle(SIColor.danger)
                    Text(log.isEmpty ? String(localized: "zsign didn't print anything.") : log)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(SIColor.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(SISpacing.md)
            }
            .siScreen()
            .navigationTitle("Signing Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        UIPasteboard.general.string = report
                        copied = true
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    .accessibilityLabel(Text("Copy Log"))
                    ShareLink(item: report) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
    }
}
