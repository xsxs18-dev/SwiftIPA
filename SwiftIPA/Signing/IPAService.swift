import Foundation
import ZIPFoundation
import UIKit

enum IPAServiceError: LocalizedError {
    case notAnIPA
    case noAppBundleFound
    case noInfoPlist
    case extractionFailed
    case repackFailed

    var errorDescription: String? {
        switch self {
        case .notAnIPA:
            return String(localized: "This doesn't look like a valid IPA file.")
        case .noAppBundleFound:
            return String(localized: "No .app bundle was found inside the Payload folder.")
        case .noInfoPlist:
            return String(localized: "The app is missing its Info.plist.")
        case .extractionFailed:
            return String(localized: "Couldn't unpack this IPA.")
        case .repackFailed:
            return String(localized: "Couldn't repack the signed app into an IPA.")
        }
    }
}

struct ExtractedApp {
    let extractionRoot: URL
    let payloadFolder: URL
    let appFolder: URL
    let infoPlistURL: URL

    func cleanUp() {
        try? FileManager.default.removeItem(at: extractionRoot)
    }
}

struct AppMetadata {
    var name: String
    var bundleIdentifier: String
    var version: String
    var build: String
    var minimumOSVersion: String
    var urlSchemes: [String]
    var hasWatchApp: Bool
    var plugins: [String]
}

enum IPAService {
    static func extract(ipaURL: URL, verifyChecksums: Bool = true) throws -> ExtractedApp {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("swiftipa-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        do {
            try fileManager.unzipItem(at: ipaURL, to: root, skipCRC32: !verifyChecksums)
        } catch {
            try? fileManager.removeItem(at: root)
            throw IPAServiceError.extractionFailed
        }

        makeWritable(at: root)

        let payload = root.appendingPathComponent("Payload", isDirectory: true)
        guard let appFolder = try? fileManager.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else {
            try? fileManager.removeItem(at: root)
            throw IPAServiceError.noAppBundleFound
        }

        let infoPlist = appFolder.appendingPathComponent("Info.plist")
        guard fileManager.fileExists(atPath: infoPlist.path) else {
            try? fileManager.removeItem(at: root)
            throw IPAServiceError.noInfoPlist
        }

        return ExtractedApp(extractionRoot: root, payloadFolder: payload, appFolder: appFolder, infoPlistURL: infoPlist)
    }

    private static func makeWritable(at root: URL) {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return }
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    static func metadata(from extracted: ExtractedApp) throws -> AppMetadata {
        guard let plist = InfoPlistPatcher.read(at: extracted.infoPlistURL) else {
            throw IPAServiceError.noInfoPlist
        }
        let fileManager = FileManager.default
        let watchExists = fileManager.fileExists(atPath: extracted.appFolder.appendingPathComponent("Watch").path)
        let pluginsFolder = extracted.appFolder.appendingPathComponent("PlugIns")
        let plugins = (try? fileManager.contentsOfDirectory(atPath: pluginsFolder.path)) ?? []
        return metadata(
            fromPlist: plist,
            fallbackName: extracted.appFolder.deletingPathExtension().lastPathComponent,
            hasWatchApp: watchExists,
            plugins: plugins
        )
    }

    private static func metadata(fromPlist plist: [String: Any], fallbackName: String, hasWatchApp: Bool, plugins: [String]) -> AppMetadata {
        let name = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String) ?? fallbackName
        var schemes: [String] = []
        for entry in (plist["CFBundleURLTypes"] as? [[String: Any]]) ?? [] {
            schemes.append(contentsOf: (entry["CFBundleURLSchemes"] as? [String]) ?? [])
        }
        return AppMetadata(
            name: name,
            bundleIdentifier: (plist["CFBundleIdentifier"] as? String) ?? "",
            version: (plist["CFBundleShortVersionString"] as? String) ?? "1.0",
            build: (plist["CFBundleVersion"] as? String) ?? "1",
            minimumOSVersion: (plist["MinimumOSVersion"] as? String) ?? "",
            urlSchemes: schemes,
            hasWatchApp: hasWatchApp,
            plugins: plugins
        )
    }

    /// Reads the metadata and icon straight from the archive instead of
    /// unpacking it, so importing a big IPA doesn't need its size again in free
    /// space. `verifyChecksums` reads every file once to check its CRC, which
    /// catches a broken download here instead of after signing.
    static func inspectArchive(at ipaURL: URL, verifyChecksums: Bool = true) throws -> (metadata: AppMetadata, icon: Data?) {
        let archive: Archive
        do {
            archive = try Archive(url: ipaURL, accessMode: .read)
        } catch {
            throw IPAServiceError.notAnIPA
        }

        var appPrefix: String?
        var appFolderName = ""
        for entry in archive where entry.type == .file {
            let parts = entry.path.split(separator: "/", omittingEmptySubsequences: false)
            if parts.count == 3, parts[0] == "Payload", parts[1].hasSuffix(".app"), parts[2] == "Info.plist" {
                appFolderName = String(parts[1])
                appPrefix = "Payload/\(appFolderName)/"
                break
            }
        }
        guard let appPrefix, let plistEntry = archive[appPrefix + "Info.plist"] else {
            throw IPAServiceError.noAppBundleFound
        }
        guard let plistData = try? readEntry(plistEntry, in: archive),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else {
            throw IPAServiceError.noInfoPlist
        }

        var hasWatchApp = false
        var plugins = Set<String>()
        var rootFiles: [String: Entry] = [:]
        for entry in archive {
            if verifyChecksums, entry.type == .file {
                let checksum: CRC32
                do {
                    checksum = try archive.extract(entry, skipCRC32: false) { _ in }
                } catch {
                    throw IPAServiceError.extractionFailed
                }
                if checksum != entry.checksum { throw IPAServiceError.extractionFailed }
            }
            guard entry.path.hasPrefix(appPrefix) else { continue }
            let inner = entry.path.dropFirst(appPrefix.count)
            if inner.hasPrefix("Watch/") { hasWatchApp = true }
            if inner.hasPrefix("PlugIns/") {
                let name = inner.dropFirst("PlugIns/".count).split(separator: "/").first.map(String.init)
                if let name, name.hasSuffix(".appex") { plugins.insert(name) }
            }
            if entry.type == .file, !inner.contains("/") { rootFiles[String(inner)] = entry }
        }

        let metadata = metadata(
            fromPlist: plist,
            fallbackName: (appFolderName as NSString).deletingPathExtension,
            hasWatchApp: hasWatchApp,
            plugins: plugins.sorted()
        )
        let icon = bestIcon(plist: plist, candidates: rootFiles.keys.sorted()) { name in
            rootFiles[name].flatMap { try? readEntry($0, in: archive) }
        }
        return (metadata, icon)
    }

    private static func readEntry(_ entry: Entry, in archive: Archive) throws -> Data {
        var data = Data()
        _ = try archive.extract(entry, skipCRC32: true) { data.append($0) }
        return data
    }

    /// The biggest PNG named like the app's icon files, or any "AppIcon" PNG.
    private static func bestIcon(plist: [String: Any], candidates: [String], load: (String) -> Data?) -> Data? {
        let icons = plist["CFBundleIcons"] as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        let iconFiles = (primary?["CFBundleIconFiles"] as? [String]) ?? []
        let pngs = candidates.filter { $0.lowercased().hasSuffix(".png") }
        var named = pngs.filter { name in iconFiles.contains { name.hasPrefix($0) } }
        if named.isEmpty { named = pngs.filter { $0.lowercased().contains("appicon") } }

        var best: (data: Data, pixels: Int)?
        for name in named {
            guard let data = load(name), let image = UIImage(data: data) else { continue }
            let pixels = Int(image.size.width * image.scale * image.size.height * image.scale)
            if pixels > (best?.pixels ?? -1) { best = (data, pixels) }
        }
        return best?.data
    }

    /// `compress: false` stores files without deflate. The IPA gets bigger but
    /// packing is several times faster, which matters most for large apps.
    static func repack(extracted: ExtractedApp, to destination: URL, compress: Bool = true) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        do {
            try fileManager.zipItem(at: extracted.payloadFolder, to: destination, shouldKeepParent: true, compressionMethod: compress ? .deflate : .none)
        } catch {
            throw IPAServiceError.repackFailed
        }
    }
}
