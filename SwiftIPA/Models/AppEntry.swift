import Foundation

struct AppEntry: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var bundleIdentifier: String
    var version: String
    var build: String
    var minimumOSVersion: String
    /// The IPA as imported. Before 1.8 signing overwrote it, so for apps signed
    /// with an older version it may already be a signed build.
    var fileName: String
    /// The signed build, next to the original.
    var signedFileName: String?
    var iconFileName: String?
    var byteSize: Int64
    var importedAt: Date
    var signedAt: Date?
    var certificateID: UUID?
    var originalBundleIdentifier: String?
    var sourceName: String?
    var presetID: UUID?

    init(
        id: UUID = UUID(),
        name: String,
        bundleIdentifier: String,
        version: String,
        build: String = "1",
        minimumOSVersion: String = "",
        fileName: String,
        signedFileName: String? = nil,
        iconFileName: String? = nil,
        byteSize: Int64 = 0,
        importedAt: Date = Date(),
        signedAt: Date? = nil,
        certificateID: UUID? = nil,
        originalBundleIdentifier: String? = nil,
        sourceName: String? = nil,
        presetID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.build = build
        self.minimumOSVersion = minimumOSVersion
        self.fileName = fileName
        self.signedFileName = signedFileName
        self.iconFileName = iconFileName
        self.byteSize = byteSize
        self.importedAt = importedAt
        self.signedAt = signedAt
        self.certificateID = certificateID
        self.originalBundleIdentifier = originalBundleIdentifier
        self.sourceName = sourceName
        self.presetID = presetID
    }

    var isSigned: Bool { signedAt != nil }

    /// The imported IPA is still there untouched (not the case for apps signed before 1.8).
    var hasOriginal: Bool { signedFileName != nil || signedAt == nil }

    var displaySize: String {
        ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }

    var displayVersion: String {
        build.isEmpty || build == version ? version : "\(version) (\(build))"
    }
}
