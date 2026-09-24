import Foundation
import Combine
import UserNotifications
import SwiftUI

final class CertificateStore: ObservableObject {
    static let shared = CertificateStore()

    @Published private(set) var certificates: [SigningCertificate] = []
    @Published var defaultCertificateID: UUID?

    private let folder: URL
    private let indexURL: URL
    private let defaults = UserDefaults.standard
    private let defaultKey = "SwiftIPA.defaultCertificateID"
    private var profileBundleIDs: [UUID: String] = [:]
    private let profileBundleIDsLock = NSLock()

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        folder = documents.appendingPathComponent("Certificates", isDirectory: true)
        indexURL = documents.appendingPathComponent("certificates-index.json")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        certificates = load()
        if let raw = defaults.string(forKey: defaultKey) {
            defaultCertificateID = UUID(uuidString: raw)
        }
    }

    func p12URL(for certificate: SigningCertificate) -> URL {
        folder.appendingPathComponent(certificate.p12FileName)
    }

    func provisionURL(for certificate: SigningCertificate) -> URL {
        folder.appendingPathComponent(certificate.provisionFileName)
    }

    func certificate(withID id: UUID?) -> SigningCertificate? {
        guard let id else { return nil }
        return certificates.first { $0.id == id }
    }

    /// Bundle ID from the certificate's provisioning profile, without the team
    /// prefix. Can be a wildcard (`*` or `com.example.*`).
    func profileBundleIdentifier(forCertificateID id: UUID?) -> String? {
        guard let certificate = certificate(withID: id) else { return nil }
        profileBundleIDsLock.lock()
        let cached = profileBundleIDs[certificate.id]
        profileBundleIDsLock.unlock()
        if let cached { return cached }

        guard let info = try? CertificateService.inspectProvisioningProfile(at: provisionURL(for: certificate)),
              let bundleID = info.bundleIdentifier else { return nil }
        profileBundleIDsLock.lock()
        profileBundleIDs[certificate.id] = bundleID
        profileBundleIDsLock.unlock()
        return bundleID
    }

    var defaultCertificate: SigningCertificate? {
        certificate(withID: defaultCertificateID) ?? certificates.first
    }

    @discardableResult
    func addCertificate(
        name: String,
        p12SourceURL: URL,
        provisionSourceURL: URL,
        password: String
    ) async throws -> SigningCertificate {
        let id = UUID()
        let folder = folder

        let certificate = try await Task.detached(priority: .userInitiated) { () -> SigningCertificate in
            let fileManager = FileManager.default
            let p12Access = p12SourceURL.startAccessingSecurityScopedResource()
            let provisionAccess = provisionSourceURL.startAccessingSecurityScopedResource()
            defer {
                if p12Access { p12SourceURL.stopAccessingSecurityScopedResource() }
                if provisionAccess { provisionSourceURL.stopAccessingSecurityScopedResource() }
            }

            let p12FileName = "\(id.uuidString).p12"
            let provisionFileName = "\(id.uuidString).mobileprovision"
            let p12Destination = folder.appendingPathComponent(p12FileName)
            let provisionDestination = folder.appendingPathComponent(provisionFileName)

            try fileManager.copyItem(at: p12SourceURL, to: p12Destination)
            try fileManager.copyItem(at: provisionSourceURL, to: provisionDestination)

            let profileInfo = try CertificateService.inspectProvisioningProfile(at: provisionDestination)
            let p12Info = try? CertificateService.inspectP12(at: p12Destination, password: password)

            var certificate = SigningCertificate(
                id: id,
                name: name,
                teamName: profileInfo.teamName,
                teamIdentifier: profileInfo.teamIdentifier,
                issuedAt: p12Info?.issuedDate,
                expiresAt: profileInfo.expirationDate,
                p12FileName: p12FileName,
                provisionFileName: provisionFileName,
                provisionedDeviceCount: profileInfo.deviceCount,
                supportsUnrestrictedEntitlements: profileInfo.supportsUnrestrictedEntitlements
            )
            certificate.lastRevocationCheck = Date()
            return certificate
        }.value

        KeychainStore.setPassword(password, forCertificateID: id)
        await MainActor.run {
            withAnimation(.easeOut(duration: 0.25)) {
                certificates.append(certificate)
            }
            if defaultCertificateID == nil {
                setDefault(certificate.id)
            }
            persist()
        }
        return certificate
    }

    func removeCertificate(_ certificate: SigningCertificate) {
        try? FileManager.default.removeItem(at: p12URL(for: certificate))
        try? FileManager.default.removeItem(at: provisionURL(for: certificate))
        KeychainStore.removePassword(forCertificateID: certificate.id)
        withAnimation(.easeOut(duration: 0.25)) {
            certificates.removeAll { $0.id == certificate.id }
        }
        if defaultCertificateID == certificate.id {
            defaultCertificateID = certificates.first?.id
            defaults.set(defaultCertificateID?.uuidString, forKey: defaultKey)
        }
        persist()
    }

    func removeAllCertificates() {
        for certificate in certificates {
            try? FileManager.default.removeItem(at: p12URL(for: certificate))
            try? FileManager.default.removeItem(at: provisionURL(for: certificate))
            KeychainStore.removePassword(forCertificateID: certificate.id)
        }
        withAnimation(.easeOut(duration: 0.25)) {
            certificates.removeAll()
        }
        defaultCertificateID = nil
        defaults.removeObject(forKey: defaultKey)
        persist()
    }

    func setDefault(_ id: UUID) {
        defaultCertificateID = id
        defaults.set(id.uuidString, forKey: defaultKey)
    }

    func password(for certificate: SigningCertificate) -> String? {
        KeychainStore.password(forCertificateID: certificate.id)
    }

    func refreshHealth(for certificate: SigningCertificate) async {
        guard let index = certificates.firstIndex(where: { $0.id == certificate.id }) else { return }
        if let profileInfo = try? CertificateService.inspectProvisioningProfile(at: provisionURL(for: certificate)) {
            await MainActor.run {
                certificates[index].expiresAt = profileInfo.expirationDate
                certificates[index].teamName = profileInfo.teamName
                certificates[index].provisionedDeviceCount = profileInfo.deviceCount
                certificates[index].lastRevocationCheck = Date()
                persist()
            }
        }
    }

    func certificatesNeedingAttention() -> [SigningCertificate] {
        certificates.filter { $0.health == .expiringSoon || $0.health == .expired || $0.health == .revoked }
    }

    func scheduleExpiryWatch() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            center.removeAllPendingNotificationRequests()
            for certificate in self.certificates {
                guard let expiresAt = certificate.expiresAt else { continue }
                let warnDate = expiresAt.addingTimeInterval(-3 * 86400)
                guard warnDate > Date() else { continue }

                let content = UNMutableNotificationContent()
                content.title = String(localized: "Certificate expiring soon")
                content.body = String(localized: "\(certificate.name) expires in 3 days. Resign your library before it goes dark.")
                content.sound = .default

                let trigger = UNCalendarNotificationTrigger(
                    dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: warnDate),
                    repeats: false
                )
                let request = UNNotificationRequest(identifier: "cert-expiry-\(certificate.id.uuidString)", content: content, trigger: trigger)
                center.add(request)
            }
        }
    }

    private func load() -> [SigningCertificate] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        return (try? JSONDecoder().decode([SigningCertificate].self, from: data)) ?? []
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(certificates) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
