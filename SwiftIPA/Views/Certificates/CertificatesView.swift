import SwiftUI

struct CertificatesView: View {
    @ObservedObject private var certificateStore = CertificateStore.shared
    @State private var showingAddSheet = false

    var body: some View {
        Group {
            if certificateStore.certificates.isEmpty {
                emptyState
            } else {
                certificateList
            }
        }
        .siScreen()
        .navigationTitle("Certificates")
        .navigationDestination(for: SigningCertificate.self) { certificate in
            CertificateDetailView(certificateID: certificate.id)
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
            AddCertificateSheet()
        }
    }

    private var certificateList: some View {
        List {
            ForEach(certificateStore.certificates) { certificate in
                NavigationLink(value: certificate) {
                    CertificateRow(certificate: certificate, isDefault: certificate.id == certificateStore.defaultCertificateID)
                }
                .buttonStyle(.siPressableCard)
            }
            .onDelete { offsets in
                for index in offsets { certificateStore.removeCertificate(certificateStore.certificates[index]) }
            }
            .listRowInsets(EdgeInsets(top: SISpacing.xs, leading: SISpacing.md, bottom: SISpacing.xs, trailing: SISpacing.md))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
    }

    private var emptyState: some View {
        SIEmptyState(
            systemImage: "checkmark.seal",
            title: "No certificates yet",
            message: "Import a .p12 and its matching .mobileprovision to start signing."
        ) {
            Button("Add Certificate") { showingAddSheet = true }
                .buttonStyle(.siPrimary)
        }
    }
}

struct CertificateRow: View {
    let certificate: SigningCertificate
    let isDefault: Bool

    var body: some View {
        HStack(spacing: SISpacing.md) {
            Image(systemName: "checkmark.seal")
                .font(.title3)
                .foregroundStyle(SIColor.accent)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(certificate.name).font(SIFont.headline)
                    if isDefault {
                        StatusBadge(text: String(localized: "Default"), color: SIColor.accent)
                    }
                }
                Text(certificate.displayExpiry).font(SIFont.caption).foregroundStyle(SIColor.textSecondary)
            }
            Spacer()
            CertificateHealthBadge(health: certificate.health)
        }
        .padding(SISpacing.sm + 2)
        .siCard()
    }
}
