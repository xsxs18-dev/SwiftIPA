import Foundation
import CryptoKit

enum FileHashing {
    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            guard let chunk = try? handle.read(upToCount: 1_048_576), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static var memo: [String: String] = [:]
    private static let memoLock = NSLock()

    /// Same as `sha256(of:)`, but remembers the result per path, size and
    /// modification date so re-signing the same IPA doesn't re-read it.
    static func cachedSHA256(of url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let memoKey = "\(url.path)|\(size)|\(modified)"

        memoLock.lock()
        let known = memo[memoKey]
        memoLock.unlock()
        if let known { return known }

        guard let hash = sha256(of: url) else { return nil }
        memoLock.lock()
        memo[memoKey] = hash
        memoLock.unlock()
        return hash
    }

    static func sha256(of string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
