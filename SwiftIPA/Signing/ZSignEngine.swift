import Foundation
#if canImport(ZSignKit)
import ZSignKit // xtool/SwiftPM build; Xcode uses the bridging header
#endif

enum ZSignEngineError: LocalizedError {
    case engineUnavailable
    case invalidCertificate(String, log: String?)
    case signingFailed(String, log: String?)

    var errorDescription: String? {
        switch self {
        case .engineUnavailable:
            return String(localized: "The signing engine isn't built into this copy of SwiftIPA. Run Scripts/fetch-dependencies.sh, then rebuild in Xcode.")
        case .invalidCertificate(let message, _):
            return message
        case .signingFailed(let message, _):
            return message
        }
    }

    /// What zsign printed, for the log view after a failed sign.
    var log: String? {
        switch self {
        case .engineUnavailable: return nil
        case .invalidCertificate(_, let log), .signingFailed(_, let log): return log
        }
    }
}

struct ZSignOutcome {
    var duration: TimeInterval
}

enum ZSignEngine {
    static var isAvailable: Bool { ZSignBridge.isEngineAvailable() }

    static func sign(
        extractionRoot: URL,
        p12URL: URL,
        p12Password: String,
        provisionURL: URL,
        entitlementsURL: URL?,
        bundleIdentifier: String?,
        bundleName: String?,
        bundleVersion: String?,
        minimumOSVersion: String?,
        iconURL: URL?,
        dylibURLs: [URL],
        removedDylibNames: [String],
        removeExtensions: Bool,
        removeWatchApp: Bool,
        removeUISupportedDevices: Bool,
        removeProvisionAfterSigning: Bool,
        weakInject: Bool,
        injectIntoExtensions: Bool,
        forceSign: Bool
    ) throws -> ZSignOutcome {
        guard isAvailable else { throw ZSignEngineError.engineUnavailable }

        let options = ZSignOptions()
        options.p12Path = p12URL.path
        options.p12Password = p12Password
        options.provisionPath = provisionURL.path
        options.entitlementsPath = entitlementsURL?.path
        options.bundleIdentifier = bundleIdentifier
        options.bundleName = bundleName
        options.bundleShortVersion = bundleVersion
        options.minimumOSVersion = minimumOSVersion
        options.iconPath = iconURL?.path
        options.dylibPathsToInject = dylibURLs.map(\.path)
        options.dylibNamesToRemove = removedDylibNames
        options.removeExtensions = removeExtensions
        options.removeWatchApp = removeWatchApp
        options.removeUISupportedDevices = removeUISupportedDevices
        options.removeProvisionAfterSigning = removeProvisionAfterSigning
        options.weakInject = weakInject
        options.injectIntoExtensions = injectIntoExtensions
        options.forceSign = forceSign
        options.adhoc = false

        let result = ZSignBridge.signAppFolder(atPath: extractionRoot.path, options: options)

        switch result.code {
        case .success:
            return ZSignOutcome(duration: result.duration)
        case .invalidCertificate:
            throw ZSignEngineError.invalidCertificate(result.message ?? String(localized: "Invalid certificate."), log: result.log)
        case .engineUnavailable:
            throw ZSignEngineError.engineUnavailable
        default:
            throw ZSignEngineError.signingFailed(result.message ?? String(localized: "Signing failed."), log: result.log)
        }
    }
}
