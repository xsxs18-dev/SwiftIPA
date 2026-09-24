import SwiftUI

struct DefaultSigningOptionsView: View {
    @ObservedObject private var defaultsStore = DefaultSigningOptionsStore.shared
    @State private var showingResetConfirmation = false

    var body: some View {
        Form {
            Section {
                Picker("Bundle ID", selection: $defaultsStore.options.bundleIdentifierRule) {
                    ForEach(BundleIdentifierRule.allCases) { rule in
                        Text(rule.displayName).tag(rule)
                    }
                }

                if defaultsStore.options.bundleIdentifierRule == .appendSuffix {
                    TextField("Suffix", text: $defaultsStore.options.bundleIdentifierSuffix)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            } header: {
                Text("Identity")
            } footer: {
                if defaultsStore.options.bundleIdentifierRule == .fromCertificate {
                    Text("Uses the bundle ID from the provisioning profile of the certificate you sign with. Wildcard profiles keep the app's own ID.")
                } else {
                    Text("Applies to every app you sign unless you change it for that sign, or a preset overrides it.")
                }
            }

            SigningOptionsEditor(options: $defaultsStore.options, certificateID: nil, showsInstallToggle: true)

            Section {
                Button(role: .destructive) {
                    showingResetConfirmation = true
                } label: {
                    Text("Reset to Defaults")
                }
            }
        }
        .siScreen()
        .navigationTitle("Default Signing Options")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: defaultsStore.options) { _ in
            defaultsStore.save()
        }
        .confirmationDialog(
            "Reset every default signing option?",
            isPresented: $showingResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                defaultsStore.resetToDefaults()
            }
        }
    }
}
