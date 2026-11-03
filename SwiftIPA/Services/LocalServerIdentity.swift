import Foundation
#if canImport(ZSignKit)
import ZSignKit // xtool/SwiftPM build; Xcode uses the bridging header
#endif
import Security
import Network

enum LocalServerIdentityError: LocalizedError {
    case generationFailed(String)
    case importFailed

    var errorDescription: String? {
        switch self {
        case .generationFailed(let message): return message
        case .importFailed: return String(localized: "Couldn't load the local server certificate.")
        }
    }
}

enum LocalServerIdentity {
    private static let fileName = "swiftipa-server-identity.p12"
    private static let passwordKey = "SwiftIPA.serverIdentityPassword"

    private static var p12URL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent(fileName)
    }

    static func ensureIdentity() throws -> (identity: SecIdentity, certificate: SecCertificate, password: String) {
        do {
            return try loadOrCreateIdentity()
        } catch {
            // The password lives in the keychain (this device only) and the .p12 in
            // Documents. After restoring a backup to another phone they no longer
            // match, so start over with a new identity instead of failing every time.
            try? FileManager.default.removeItem(at: p12URL)
            return try loadOrCreateIdentity(forceNewPassword: true)
        }
    }

    private static func loadOrCreateIdentity(forceNewPassword: Bool = false) throws -> (identity: SecIdentity, certificate: SecCertificate, password: String) {
        let password = (forceNewPassword ? nil : existingPassword()) ?? newPassword()

        if !FileManager.default.fileExists(atPath: p12URL.path) {
            var errorMessage: NSString?
            let success = ZSignBridge.generateSelfSignedIdentity(
                atP12Path: p12URL.path,
                password: password,
                commonName: "SwiftIPA Local Server",
                validityInDays: 3650,
                error: &errorMessage
            )
            guard success else {
                throw LocalServerIdentityError.generationFailed(errorMessage as String? ?? "unknown error")
            }
        }

        return try importIdentity(password: password)
    }

    static var trustedCertificateURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwiftIPA-Local-CA.cer")
    }

    static func exportTrustCertificate() throws -> URL {
        let (_, certificate, _) = try ensureIdentity()
        let data = SecCertificateCopyData(certificate) as Data
        try data.write(to: trustedCertificateURL, options: .atomic)
        return trustedCertificateURL
    }

    private static func importIdentity(password: String) throws -> (SecIdentity, SecCertificate, String) {
        let data = try Data(contentsOf: p12URL)
        let options: [String: Any] = [kSecImportExportPassphrase as String: password]
        var rawItems: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &rawItems)
        guard status == errSecSuccess,
              let items = rawItems as? [[String: Any]],
              let first = items.first,
              let identityValue = first[kSecImportItemIdentity as String],
              CFGetTypeID(identityValue as CFTypeRef) == SecIdentityGetTypeID() else {
            throw LocalServerIdentityError.importFailed
        }

        let secIdentity = identityValue as! SecIdentity
        var certificate: SecCertificate?
        SecIdentityCopyCertificate(secIdentity, &certificate)
        guard let certificate else { throw LocalServerIdentityError.importFailed }

        return (secIdentity, certificate, password)
    }

    private static func existingPassword() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.xsxs18.SwiftIPA.serverIdentity",
            kSecAttrAccount as String: passwordKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func newPassword() -> String {
        let generated = UUID().uuidString
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.xsxs18.SwiftIPA.serverIdentity",
            kSecAttrAccount as String: passwordKey,
            kSecValueData as String: Data(generated.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemDelete(attributes as CFDictionary)
        SecItemAdd(attributes as CFDictionary, nil)
        return generated
    }
}
