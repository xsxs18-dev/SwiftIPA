import Foundation

struct SigningCacheEntry: Codable {
    var key: String
    var ipaFileName: String
    var createdAt: Date
    var byteSize: Int64
    /// The bundle ID the cached build was signed with. Missing in entries from before 1.8.
    var bundleIdentifier: String?
}

final class SigningCache {
    static let shared = SigningCache()

    private let directory: URL
    private let indexURL: URL
    private let maxTotalBytes: Int64 = 3_000_000_000
    private let queue = DispatchQueue(label: "com.xsxs18.SwiftIPA.SigningCache")

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("SignCache", isDirectory: true)
        indexURL = directory.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func key(sourceHash: String, optionsFingerprint: String, certificateFingerprint: String) -> String {
        FileHashing.sha256(of: "\(sourceHash)|\(optionsFingerprint)|\(certificateFingerprint)")
    }

    func cachedIPA(for key: String) -> (url: URL, bundleIdentifier: String?)? {
        queue.sync {
            var index = readIndex()
            guard let entry = index[key] else { return nil }
            let fileURL = directory.appendingPathComponent(entry.ipaFileName)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                index.removeValue(forKey: key)
                writeIndex(index)
                return nil
            }
            return (fileURL, entry.bundleIdentifier)
        }
    }

    func store(key: String, ipaURL: URL, bundleIdentifier: String?) {
        queue.sync {
            var index = readIndex()
            let fileName = "\(key).ipa"
            let destination = directory.appendingPathComponent(fileName)
            guard (try? FileManager.default.replaceItem(at: destination, withItemAt: ipaURL)) != nil else { return }

            let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
            index[key] = SigningCacheEntry(key: key, ipaFileName: fileName, createdAt: Date(), byteSize: size, bundleIdentifier: bundleIdentifier)
            writeIndex(index)
            evictIfNeeded(index: &index)
        }
    }

    func clear() {
        queue.sync {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    var totalSize: Int64 {
        queue.sync { readIndex().values.reduce(0) { $0 + $1.byteSize } }
    }

    private func readIndex() -> [String: SigningCacheEntry] {
        guard let data = try? Data(contentsOf: indexURL) else { return [:] }
        return (try? JSONDecoder().decode([String: SigningCacheEntry].self, from: data)) ?? [:]
    }

    private func writeIndex(_ index: [String: SigningCacheEntry]) {
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private func evictIfNeeded(index: inout [String: SigningCacheEntry]) {
        var total = index.values.reduce(0) { $0 + $1.byteSize }
        guard total > maxTotalBytes else { return }

        let oldestFirst = index.values.sorted { $0.createdAt < $1.createdAt }
        for entry in oldestFirst {
            guard total > maxTotalBytes else { break }
            let fileURL = directory.appendingPathComponent(entry.ipaFileName)
            try? FileManager.default.removeItem(at: fileURL)
            index.removeValue(forKey: entry.key)
            total -= entry.byteSize
        }
        writeIndex(index)
    }
}
