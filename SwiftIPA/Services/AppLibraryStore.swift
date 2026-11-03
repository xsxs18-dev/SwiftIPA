import Foundation
import Combine
import SwiftUI

final class AppLibraryStore: ObservableObject {
    static let shared = AppLibraryStore()

    @Published private(set) var apps: [AppEntry] = []

    let folder: URL
    private let indexURL: URL

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        folder = documents.appendingPathComponent("Library", isDirectory: true)
        indexURL = documents.appendingPathComponent("library-index.json")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        apps = load()
    }

    /// The IPA to install or export: the signed build if there is one.
    func ipaURL(for entry: AppEntry) -> URL {
        if let signed = entry.signedFileName { return folder.appendingPathComponent(signed) }
        return originalIPAURL(for: entry)
    }

    /// The IPA as it was imported. Signing always starts from this one, so
    /// signing again doesn't pile changes (suffixes, tweaks) on top of the last build.
    func originalIPAURL(for entry: AppEntry) -> URL {
        folder.appendingPathComponent(entry.fileName)
    }

    private func files(of entry: AppEntry) -> [URL] {
        [entry.fileName, entry.signedFileName, entry.iconFileName].compactMap { $0 }.map { folder.appendingPathComponent($0) }
    }

    func iconURL(for entry: AppEntry) -> URL? {
        guard let name = entry.iconFileName else { return nil }
        return folder.appendingPathComponent(name)
    }

    @discardableResult
    func importIPA(at sourceURL: URL, sourceName: String? = nil) async throws -> AppEntry {
        let folder = folder
        let entry = try await Task.detached(priority: .userInitiated) {
            try Self.performImport(sourceURL: sourceURL, sourceName: sourceName, folder: folder)
        }.value

        await MainActor.run {
            withAnimation(.easeOut(duration: 0.25)) {
                apps.insert(entry, at: 0)
            }
            persist()
        }
        return entry
    }

    private static func performImport(sourceURL: URL, sourceName: String?, folder: URL) throws -> AppEntry {
        let fileManager = FileManager.default
        let needsAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if needsAccess { sourceURL.stopAccessingSecurityScopedResource() } }

        let id = UUID()
        let fileName = "\(id.uuidString).ipa"
        let destination = folder.appendingPathComponent(fileName)
        try fileManager.copyItem(at: sourceURL, to: destination)

        let inspection: (metadata: AppMetadata, icon: Data?)
        do {
            inspection = try IPAService.inspectArchive(at: destination)
        } catch {
            // Don't leave a broken copy behind in the library folder.
            try? fileManager.removeItem(at: destination)
            throw error
        }
        let metadata = inspection.metadata

        var iconFileName: String?
        if let iconData = inspection.icon {
            let name = "\(id.uuidString)-icon.png"
            try? iconData.write(to: folder.appendingPathComponent(name))
            iconFileName = name
        }

        // Files opened from other apps get copied into Documents/Inbox, which
        // would otherwise keep a second copy of every shared IPA.
        let inbox = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Inbox", isDirectory: true).standardizedFileURL.path
        if sourceURL.standardizedFileURL.path.hasPrefix(inbox + "/") {
            try? fileManager.removeItem(at: sourceURL)
        }

        let size = (try? fileManager.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0

        return AppEntry(
            id: id,
            name: metadata.name,
            bundleIdentifier: metadata.bundleIdentifier,
            version: metadata.version,
            build: metadata.build,
            minimumOSVersion: metadata.minimumOSVersion,
            fileName: fileName,
            iconFileName: iconFileName,
            byteSize: size,
            originalBundleIdentifier: metadata.bundleIdentifier,
            sourceName: sourceName
        )
    }

    /// `bundleIdentifier` is the ID the app was actually signed with. It's nil
    /// when the result came from the cache, then it gets worked out again here.
    func markSigned(_ entryID: UUID, signedIPAURL: URL, bundleIdentifier: String?, options: SigningOptions, certificateID: UUID) async throws {
        guard let entry = await MainActor.run(body: { apps.first(where: { $0.id == entryID }) }) else { return }
        // The signed build goes next to the original, which stays as it was imported.
        let signedFileName = entry.hasOriginal ? "\(entry.id.uuidString)-signed.ipa" : entry.fileName
        let destination = folder.appendingPathComponent(signedFileName)

        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.replaceItem(at: destination, withItemAt: signedIPAURL)
        }.value

        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0

        await MainActor.run {
            guard let index = apps.firstIndex(where: { $0.id == entryID }) else { return }
            if apps[index].hasOriginal { apps[index].signedFileName = signedFileName }
            apps[index].byteSize = size
            apps[index].signedAt = Date()
            apps[index].certificateID = certificateID
            if let bundleIdentifier {
                apps[index].bundleIdentifier = bundleIdentifier
            } else if options.bundleIdentifierRule != .randomSuffix {
                apps[index].bundleIdentifier = options.resolvedBundleIdentifier(
                    original: apps[index].originalBundleIdentifier ?? apps[index].bundleIdentifier,
                    certificateBundleID: CertificateStore.shared.profileBundleIdentifier(forCertificateID: certificateID)
                )
            }
            if !options.displayName.isEmpty { apps[index].name = options.displayName }
            if !options.version.isEmpty { apps[index].version = options.version }
            if !options.build.isEmpty { apps[index].build = options.build }
            persist()
        }
    }

    func remove(_ entry: AppEntry) {
        for url in files(of: entry) { try? FileManager.default.removeItem(at: url) }
        withAnimation(.easeOut(duration: 0.25)) {
            apps.removeAll { $0.id == entry.id }
        }
        persist()
    }

    func removeAll(where predicate: (AppEntry) -> Bool) {
        for entry in apps where predicate(entry) {
            for url in files(of: entry) { try? FileManager.default.removeItem(at: url) }
        }
        withAnimation(.easeOut(duration: 0.25)) {
            apps.removeAll(where: predicate)
        }
        persist()
    }

    func rename(_ entry: AppEntry, to newName: String) {
        guard let index = apps.firstIndex(where: { $0.id == entry.id }) else { return }
        apps[index].name = newName
        persist()
    }

    private func load() -> [AppEntry] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        return (try? JSONDecoder().decode([AppEntry].self, from: data)) ?? []
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(apps) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
