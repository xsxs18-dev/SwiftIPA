import SwiftUI
import UIKit

/// Builds a prefilled GitHub issue and opens it in the browser, so reporting
/// a bug is one tap after writing it down.
struct BugReportView: View {
    static let repositoryURL = URL(string: "https://github.com/xsxs18-dev/SwiftIPA")!

    enum Kind: String, CaseIterable, Identifiable {
        case bug
        case feature
        case question

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .bug: return String(localized: "Bug")
            case .feature: return String(localized: "Feature Request")
            case .question: return String(localized: "Question")
            }
        }

        var label: String {
            switch self {
            case .bug: return "bug"
            case .feature: return "enhancement"
            case .question: return "question"
            }
        }

        var titlePrefix: String {
            switch self {
            case .bug: return "[Bug]"
            case .feature: return "[Feature]"
            case .question: return "[Question]"
            }
        }
    }

    @State private var kind: Kind = .bug
    @State private var title = ""
    @State private var details = ""
    @State private var steps = ""
    @State private var includeDeviceInfo = true
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section {
                Picker("Type", selection: $kind) {
                    ForEach(Kind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            Section {
                TextField("Short summary", text: $title)
                ZStack(alignment: .topLeading) {
                    if details.isEmpty {
                        Text(kind == .feature ? LocalizedStringKey("What would you like SwiftIPA to do?") : LocalizedStringKey("What happened, and what did you expect?"))
                            .foregroundStyle(SIColor.textSecondary)
                            .padding(.top, 8)
                            .padding(.leading, 4)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $details)
                        .frame(minHeight: 110)
                        .scrollContentBackground(.hidden)
                }
            } header: {
                Text("Report")
            }

            if kind == .bug {
                Section {
                    ZStack(alignment: .topLeading) {
                        if steps.isEmpty {
                            Text("1. Open …\n2. Tap …\n3. …")
                                .foregroundStyle(SIColor.textSecondary)
                                .padding(.top, 8)
                                .padding(.leading, 4)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $steps)
                            .frame(minHeight: 80)
                            .scrollContentBackground(.hidden)
                    }
                } header: {
                    Text("Steps to Reproduce")
                }
            }

            Section {
                Toggle("Include Device Info", isOn: $includeDeviceInfo)
                if includeDeviceInfo {
                    Text(Self.deviceInfo)
                        .font(SIFont.mono)
                        .foregroundStyle(SIColor.textSecondary)
                        .textSelection(.enabled)
                }
            } footer: {
                Text("Only what's shown here is added. Nothing is sent until you submit the issue on GitHub.")
            }

            Section {
                Button {
                    openURL(issueURL)
                } label: {
                    Label("Open Issue on GitHub", systemImage: "arrow.up.right.square")
                }
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Link(destination: Self.repositoryURL.appendingPathComponent("issues")) {
                    Label("View Open Issues", systemImage: "list.bullet")
                }
            } footer: {
                Text("Opens github.com with the issue already filled in. You need a GitHub account to submit it.")
            }
        }
        .siScreen()
        .navigationTitle("Bugs & Issues")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var issueURL: URL {
        var body = ""
        let trimmedDetails = details.trimmingCharacters(in: .whitespacesAndNewlines)
        body += "### Description\n\n\(trimmedDetails.isEmpty ? "_No description_" : trimmedDetails)\n\n"
        let trimmedSteps = steps.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == .bug, !trimmedSteps.isEmpty {
            body += "### Steps to reproduce\n\n\(trimmedSteps)\n\n"
        }
        if includeDeviceInfo {
            body += "### Device\n\n```\n\(Self.deviceInfo)\n```\n"
        }
        body += "\n_Sent from SwiftIPA's bug reporter._"

        // Browsers and GitHub cut off very long URLs.
        if body.count > 2500 {
            body = String(body.prefix(2500)) + "\n…"
        }

        let summary = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Encode everything but unreserved characters, so "&", "=", "+" and "#"
        // in the text can't break the query.
        let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        func encode(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
        }
        let query = [
            "title=" + encode("\(kind.titlePrefix) \(summary)"),
            "body=" + encode(body),
            "labels=" + encode(kind.label),
        ].joined(separator: "&")
        return URL(string: Self.repositoryURL.absoluteString + "/issues/new?" + query) ?? Self.repositoryURL
    }

    static var deviceInfo: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let device = UIDevice.current
        return [
            "SwiftIPA: \(version) (\(build))",
            "iOS: \(device.systemVersion)",
            "Device: \(modelIdentifier)",
            "Language: \(Locale.preferredLanguages.first ?? "?")",
            "Certificates: \(CertificateStore.shared.certificates.count)",
            "Tweaks: \(DylibLibraryStore.shared.dylibs.count)",
        ].joined(separator: "\n")
    }

    private static var modelIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let identifier = withUnsafeBytes(of: &systemInfo.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
        return identifier.isEmpty ? UIDevice.current.model : identifier
    }
}
