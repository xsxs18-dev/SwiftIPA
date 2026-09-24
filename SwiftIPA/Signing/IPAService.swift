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

        let name = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String) ?? extracted.appFolder.deletingPathExtension().lastPathComponent
        let bundleID = (plist["CFBundleIdentifier"] as? String) ?? ""
        let version = (plist["CFBundleShortVersionString"] as? String) ?? "1.0"
        let build = (plist["CFBundleVersion"] as? String) ?? "1"
        let minimumOS = (plist["MinimumOSVersion"] as? String) ?? ""

        var schemes: [String] = []
        if let urlTypes = plist["CFBundleURLTypes"] as? [[String: Any]] {
            for entry in urlTypes {
                if let names = entry["CFBundleURLSchemes"] as? [String] {
                    schemes.append(contentsOf: names)
                }
            }
        }

        let fileManager = FileManager.default
        let watchExists = fileManager.fileExists(atPath: extracted.appFolder.appendingPathComponent("Watch").path)
        let pluginsFolder = extracted.appFolder.appendingPathComponent("PlugIns")
        let plugins = (try? fileManager.contentsOfDirectory(atPath: pluginsFolder.path)) ?? []

        return AppMetadata(
            name: name,
            bundleIdentifier: bundleID,
            version: version,
            build: build,
            minimumOSVersion: minimumOS,
            urlSchemes: schemes,
            hasWatchApp: watchExists,
            plugins: plugins
        )
    }

    static func extractIcon(from extracted: ExtractedApp) -> Data? {
        guard let plist = InfoPlistPatcher.read(at: extracted.infoPlistURL) else { return nil }
        let icons = plist["CFBundleIcons"] as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        let files = (primary?["CFBundleIconFiles"] as? [String]) ?? []

        let fileManager = FileManager.default
        let candidates = (try? fileManager.contentsOfDirectory(atPath: extracted.appFolder.path)) ?? []

        var bestURL: URL?
        var bestSize = -1

        for base in files {
            for candidate in candidates where candidate.hasPrefix(base) && candidate.hasSuffix(".png") {
                let url = extracted.appFolder.appendingPathComponent(candidate)
                if let image = UIImage(contentsOfFile: url.path) {
                    let size = Int(image.size.width * image.size.height)
                    if size > bestSize {
                        bestSize = size
                        bestURL = url
                    }
                }
            }
        }

        if bestURL == nil {
            for candidate in candidates where candidate.lowercased().contains("appicon") && candidate.hasSuffix(".png") {
                let url = extracted.appFolder.appendingPathComponent(candidate)
                if let image = UIImage(contentsOfFile: url.path) {
                    let size = Int(image.size.width * image.size.height)
                    if size > bestSize {
                        bestSize = size
                        bestURL = url
                    }
                }
            }
        }

        guard let iconURL = bestURL else { return nil }
        return try? Data(contentsOf: iconURL)
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
