import Foundation

enum BundleIdentifierRule: String, Codable, CaseIterable, Identifiable {
    case keepOriginal
    case appendSuffix
    case randomSuffix
    case fromCertificate
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .keepOriginal: return String(localized: "Keep original")
        case .appendSuffix: return String(localized: "Append suffix")
        case .randomSuffix: return String(localized: "Random suffix")
        case .fromCertificate: return String(localized: "From certificate")
        case .custom: return String(localized: "Custom")
        }
    }
}

enum AppAppearance: String, Codable, CaseIterable, Identifiable {
    case automatic
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: return String(localized: "Automatic")
        case .light: return String(localized: "Light")
        case .dark: return String(localized: "Dark")
        }
    }

    var plistValue: String? {
        switch self {
        case .automatic: return nil
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

enum LiquidGlassMode: String, Codable, CaseIterable, Identifiable {
    case automatic
    case disabled
    case forced

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: return String(localized: "Automatic")
        case .disabled: return String(localized: "Disable Liquid Glass")
        case .forced: return String(localized: "Force Liquid Glass")
        }
    }
}

struct SigningOptions: Codable, Hashable {
    var displayName: String = ""
    var bundleIdentifier: String = ""
    var bundleIdentifierRule: BundleIdentifierRule = .keepOriginal
    var bundleIdentifierSuffix: String = ""
    var version: String = ""
    var build: String = ""
    var minimumOSVersion: String = ""
    var customIconPath: String?
    var entitlements: String?
    var appearance: AppAppearance = .automatic
    var liquidGlassMode: LiquidGlassMode = .automatic

    var removePlugins: Bool = false
    var removeWatchApp: Bool = false
    var removeLocalizations: Bool = false
    var removeDeviceRestrictions: Bool = true
    var removeURLSchemes: Bool = false
    var removeProvisioningProfile: Bool = false

    var forceFileSharing: Bool = false
    var forceDocumentBrowser: Bool = false
    var forceProMotion: Bool = false
    var forceFullScreen: Bool = false
    var forceGameMode: Bool = false
    var forceLocalNetworkAccess: Bool = false
    var allowArbitraryLoads: Bool = false
    var forceLocalizedDisplayName: Bool = false

    var injectedDylibIDs: [UUID] = []
    var weakInjection: Bool = true
    var injectAtFront: Bool = false
    var injectIntoExtensions: Bool = false

    var installAfterSigning: Bool = false
    var useCache: Bool = true
    var stripExistingSignature: Bool = true
    var fastPackaging: Bool = true

    init() {}

    /// `certificateBundleID` is the bundle ID from the certificate's provisioning
    /// profile, without the team prefix. It can be a wildcard like `*` or `com.example.*`.
    func resolvedBundleIdentifier(original: String, certificateBundleID: String? = nil) -> String {
        switch bundleIdentifierRule {
        case .keepOriginal:
            return original
        case .appendSuffix:
            let suffix = bundleIdentifierSuffix.trimmingCharacters(in: .whitespaces)
            return suffix.isEmpty ? original : "\(original).\(suffix)"
        case .randomSuffix:
            return "\(original).\(String(UUID().uuidString.prefix(6)).lowercased())"
        case .fromCertificate:
            return Self.bundleIdentifier(fromCertificateID: certificateBundleID, original: original)
        case .custom:
            let custom = bundleIdentifier.trimmingCharacters(in: .whitespaces)
            return custom.isEmpty ? original : custom
        }
    }

    static func bundleIdentifier(fromCertificateID certificateBundleID: String?, original: String) -> String {
        guard let certificateBundleID, !certificateBundleID.isEmpty, certificateBundleID != "*" else {
            return original
        }
        guard certificateBundleID.hasSuffix("*") else { return certificateBundleID }
        // Wildcard like com.example.* - fill the star with the app's own last component.
        let prefix = String(certificateBundleID.dropLast()).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let last = original.split(separator: ".").last.map(String.init) ?? "app"
        return prefix.isEmpty ? original : "\(prefix).\(last)"
    }

    // Every field is decoded leniently so presets and defaults saved by older
    // versions keep loading after new options are added.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SigningOptions()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        displayName = value(.displayName, d.displayName)
        bundleIdentifier = value(.bundleIdentifier, d.bundleIdentifier)
        bundleIdentifierRule = value(.bundleIdentifierRule, d.bundleIdentifierRule)
        bundleIdentifierSuffix = value(.bundleIdentifierSuffix, d.bundleIdentifierSuffix)
        version = value(.version, d.version)
        build = value(.build, d.build)
        minimumOSVersion = value(.minimumOSVersion, d.minimumOSVersion)
        customIconPath = value(.customIconPath, d.customIconPath)
        entitlements = value(.entitlements, d.entitlements)
        appearance = value(.appearance, d.appearance)
        liquidGlassMode = value(.liquidGlassMode, d.liquidGlassMode)
        removePlugins = value(.removePlugins, d.removePlugins)
        removeWatchApp = value(.removeWatchApp, d.removeWatchApp)
        removeLocalizations = value(.removeLocalizations, d.removeLocalizations)
        removeDeviceRestrictions = value(.removeDeviceRestrictions, d.removeDeviceRestrictions)
        removeURLSchemes = value(.removeURLSchemes, d.removeURLSchemes)
        removeProvisioningProfile = value(.removeProvisioningProfile, d.removeProvisioningProfile)
        forceFileSharing = value(.forceFileSharing, d.forceFileSharing)
        forceDocumentBrowser = value(.forceDocumentBrowser, d.forceDocumentBrowser)
        forceProMotion = value(.forceProMotion, d.forceProMotion)
        forceFullScreen = value(.forceFullScreen, d.forceFullScreen)
        forceGameMode = value(.forceGameMode, d.forceGameMode)
        forceLocalNetworkAccess = value(.forceLocalNetworkAccess, d.forceLocalNetworkAccess)
        allowArbitraryLoads = value(.allowArbitraryLoads, d.allowArbitraryLoads)
        forceLocalizedDisplayName = value(.forceLocalizedDisplayName, d.forceLocalizedDisplayName)
        injectedDylibIDs = value(.injectedDylibIDs, d.injectedDylibIDs)
        weakInjection = value(.weakInjection, d.weakInjection)
        injectAtFront = value(.injectAtFront, d.injectAtFront)
        injectIntoExtensions = value(.injectIntoExtensions, d.injectIntoExtensions)
        installAfterSigning = value(.installAfterSigning, d.installAfterSigning)
        useCache = value(.useCache, d.useCache)
        stripExistingSignature = value(.stripExistingSignature, d.stripExistingSignature)
        fastPackaging = value(.fastPackaging, d.fastPackaging)
    }

    var touchesBundleContents: Bool {
        removePlugins || removeWatchApp || removeLocalizations
            || removeURLSchemes || !injectedDylibIDs.isEmpty || customIconPath != nil
    }
}
