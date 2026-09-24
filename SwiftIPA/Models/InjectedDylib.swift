import Foundation

struct InjectedDylib: Identifiable, Codable, Hashable {
    let id: UUID
    var fileName: String
    var displayName: String
    var isWeak: Bool
    var addedAt: Date
    var byteSize: Int64
    /// Name of the .deb this dylib came from, if any.
    var packageName: String?
    /// Provides CydiaSubstrate / ElleKit for other tweaks (e.g. libellekit.dylib).
    var isSubstrateProvider: Bool

    init(
        id: UUID = UUID(),
        fileName: String,
        displayName: String,
        isWeak: Bool = true,
        addedAt: Date = Date(),
        byteSize: Int64 = 0,
        packageName: String? = nil,
        isSubstrateProvider: Bool = false
    ) {
        self.id = id
        self.fileName = fileName
        self.displayName = displayName
        self.isWeak = isWeak
        self.addedAt = addedAt
        self.byteSize = byteSize
        self.packageName = packageName
        self.isSubstrateProvider = isSubstrateProvider
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        fileName = try container.decode(String.self, forKey: .fileName)
        displayName = try container.decode(String.self, forKey: .displayName)
        isWeak = try container.decodeIfPresent(Bool.self, forKey: .isWeak) ?? true
        addedAt = try container.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        byteSize = try container.decodeIfPresent(Int64.self, forKey: .byteSize) ?? 0
        packageName = try container.decodeIfPresent(String.self, forKey: .packageName)
        isSubstrateProvider = try container.decodeIfPresent(Bool.self, forKey: .isSubstrateProvider) ?? false
    }

    var isDebPackage: Bool {
        packageName != nil || fileName.lowercased().hasSuffix(".deb")
    }

    var displaySize: String {
        ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }
}

/// What a tweak needs at runtime, read from its load commands.
struct TweakAnalysis: Hashable {
    var needsSubstrate: Bool
    var jailbreakOnlyLibraries: [String]
}
