import Foundation
import Security

struct ProvisioningProfileInfo {
    var name: String
    var teamName: String?
    var teamIdentifier: String?
    var applicationIdentifierPrefix: String?
    var creationDate: Date?
    var expirationDate: Date?
    var deviceCount: Int?
    var entitlements: [String: Any]
    var supportsUnrestrictedEntitlements: Bool
    var applicationIdentifier: String?

    /// The profile's App ID without the team prefix, e.g. `com.example.app` or `*`.
    var bundleIdentifier: String? {
        guard let applicationIdentifier, !applicationIdentifier.isEmpty else { return nil }
        if let prefix = applicationIdentifierPrefix, applicationIdentifier.hasPrefix(prefix + ".") {
            return String(applicationIdentifier.dropFirst(prefix.count + 1))
        }
        guard let dot = applicationIdentifier.firstIndex(of: ".") else { return applicationIdentifier }
        return String(applicationIdentifier[applicationIdentifier.index(after: dot)...])
    }
}

struct P12Info {
    var subjectCommonName: String?
    var expirationDate: Date?
    var issuedDate: Date?
}

enum CertificateServiceError: LocalizedError {
    case cannotReadProfile
    case wrongPassword
    case cannotReadP12

    var errorDescription: String? {
        switch self {
        case .cannotReadProfile:
            return String(localized: "Couldn't read this provisioning profile.")
        case .wrongPassword:
            return String(localized: "That password doesn't unlock this .p12 file.")
        case .cannotReadP12:
            return String(localized: "Couldn't read this .p12 certificate file.")
        }
    }
}

enum CertificateService {
    static func inspectProvisioningProfile(at url: URL) throws -> ProvisioningProfileInfo {
        let raw = try Data(contentsOf: url)

        guard let contentData = ZSignBridge.cmsContent(from: raw) else {
            throw CertificateServiceError.cannotReadProfile
        }

        guard let plist = try? PropertyListSerialization.propertyList(from: contentData, format: nil) as? [String: Any] else {
            throw CertificateServiceError.cannotReadProfile
        }

        let entitlements = (plist["Entitlements"] as? [String: Any]) ?? [:]
        let unrestricted = (entitlements["get-task-allow"] as? Bool) == true
            || (entitlements["com.apple.private.security.no-container"] as? Bool) == true

        return ProvisioningProfileInfo(
            name: (plist["Name"] as? String) ?? url.deletingPathExtension().lastPathComponent,
            teamName: plist["TeamName"] as? String,
            teamIdentifier: (plist["TeamIdentifier"] as? [String])?.first,
            applicationIdentifierPrefix: (plist["ApplicationIdentifierPrefix"] as? [String])?.first,
            creationDate: plist["CreationDate"] as? Date,
            expirationDate: plist["ExpirationDate"] as? Date,
            deviceCount: (plist["ProvisionedDevices"] as? [String])?.count,
            entitlements: entitlements,
            supportsUnrestrictedEntitlements: unrestricted,
            applicationIdentifier: entitlements["application-identifier"] as? String
        )
    }

    static func inspectP12(at url: URL, password: String) throws -> P12Info {
        let data = try Data(contentsOf: url)
        let options: [String: Any] = [kSecImportExportPassphrase as String: password]
        var rawItems: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &rawItems)

        guard status == errSecSuccess else {
            if status == errSecAuthFailed || status == -25264 {
                throw CertificateServiceError.wrongPassword
            }
            throw CertificateServiceError.cannotReadP12
        }

        guard let items = rawItems as? [[String: Any]], let first = items.first,
              let identityValue = first[kSecImportItemIdentity as String],
              CFGetTypeID(identityValue as CFTypeRef) == SecIdentityGetTypeID() else {
            throw CertificateServiceError.cannotReadP12
        }
        let identity = identityValue as! SecIdentity

        var certificate: SecCertificate?
        SecIdentityCopyCertificate(identity, &certificate)
        guard let certificate else { throw CertificateServiceError.cannotReadP12 }

        var commonName: CFString?
        SecCertificateCopyCommonName(certificate, &commonName)

        let certificateData = SecCertificateCopyData(certificate) as Data
        let notAfter = ZSignBridge.notAfterDate(forCertificateData: certificateData)
        let notBefore = ZSignBridge.notBeforeDate(forCertificateData: certificateData)

        return P12Info(
            subjectCommonName: commonName as String?,
            expirationDate: notAfter,
            issuedDate: notBefore
        )
    }
}
