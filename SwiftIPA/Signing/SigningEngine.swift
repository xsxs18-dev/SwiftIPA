import Foundation

enum SigningEngineError: LocalizedError {
    case certificateMissing
    case certificatePasswordMissing
    case noAppEntry
    case substrateMissing(String)

    var errorDescription: String? {
        switch self {
        case .certificateMissing:
            return String(localized: "No signing certificate is selected.")
        case .certificatePasswordMissing:
            return String(localized: "SwiftIPA doesn't have a saved password for this certificate. Re-add it from Certificates.")
        case .noAppEntry:
            return String(localized: "This app is no longer in your library.")
        case .substrateMissing(let tweak):
            return String(localized: "\(tweak) needs CydiaSubstrate or ElleKit. Import ElleKit's .deb (or libellekit.dylib) in the Tweak Library, then sign again.")
        }
    }
}

actor SigningEngine {
    static let shared = SigningEngine()

    private let cache = SigningCache.shared

    func run(jobs: [SigningJob]) async {
        let concurrency = max(1, min(ProcessInfo.processInfo.activeProcessorCount, jobs.count))
        await withTaskGroup(of: Void.self) { group in
            var iterator = jobs.makeIterator()
            var launched = 0

            func launchNext() {
                guard let job = iterator.next() else { return }
                launched += 1
                group.addTask { [weak self] in
                    await self?.execute(job)
                }
            }

            for _ in 0..<concurrency { launchNext() }
            while launched > 0 {
                await group.next()
                launched -= 1
                launchNext()
            }
        }
    }

    private func execute(_ job: SigningJob) async {
        do {
            let result = try await sign(job: job)
            try await AppLibraryStore.shared.markSigned(
                job.appEntryID,
                signedIPAURL: result.url,
                bundleIdentifier: result.bundleIdentifier,
                options: job.options,
                certificateID: job.certificateID
            )
            try? FileManager.default.removeItem(at: result.url)
        } catch {
            await MainActor.run { job.status = .failed(error.localizedDescription) }
        }
    }

    private func sign(job: SigningJob) async throws -> (url: URL, bundleIdentifier: String?) {
        guard let certificate = CertificateStore.shared.certificate(withID: job.certificateID) else {
            await MainActor.run { job.status = .failed(SigningEngineError.certificateMissing.localizedDescription) }
            throw SigningEngineError.certificateMissing
        }
        guard let password = CertificateStore.shared.password(for: certificate) else {
            await MainActor.run { job.status = .failed(SigningEngineError.certificatePasswordMissing.localizedDescription) }
            throw SigningEngineError.certificatePasswordMissing
        }

        await MainActor.run { job.status = .extracting }

        let p12URL = CertificateStore.shared.p12URL(for: certificate)
        let provisionURL = CertificateStore.shared.provisionURL(for: certificate)

        let certificateBundleID = CertificateStore.shared.profileBundleIdentifier(forCertificateID: certificate.id)

        var cacheKey: String?
        if job.options.useCache,
           let sourceHash = FileHashing.cachedSHA256(of: job.sourceIPAURL),
           let optionsData = try? JSONEncoder().encode(job.options) {
            let optionsFingerprint = FileHashing.sha256(of: String(data: optionsData, encoding: .utf8) ?? "")
            let certFingerprint = (FileHashing.cachedSHA256(of: p12URL) ?? "") + (FileHashing.cachedSHA256(of: provisionURL) ?? "")
            let key = cache.key(sourceHash: sourceHash, optionsFingerprint: optionsFingerprint, certificateFingerprint: certFingerprint)
            cacheKey = key
            if let cached = cache.cachedIPA(for: key) {
                await MainActor.run { job.status = .cached }
                let tempCopy = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).ipa")
                try FileManager.default.replaceItem(at: tempCopy, withItemAt: cached)
                await MainActor.run { job.status = .done(0) }
                return (tempCopy, nil)
            }
        }

        let started = Date()
        // The IPA is already in the library and was checked on import, so skip CRC checks.
        let extracted = try IPAService.extract(ipaURL: job.sourceIPAURL, verifyChecksums: false)
        defer { extracted.cleanUp() }

        await MainActor.run { job.status = .patching }
        try InfoPlistPatcher.apply(job.options, toPlistAt: extracted.infoPlistURL)
        if job.options.removeLocalizations {
            InfoPlistPatcher.removeLocalizations(inAppFolder: extracted.appFolder)
        }
        if job.options.forceLocalizedDisplayName, !job.options.displayName.isEmpty {
            InfoPlistPatcher.forceLocalizedDisplayName(job.options.displayName, inAppFolder: extracted.appFolder)
        }

        var entitlementsURL: URL?
        if let entitlementsText = job.options.entitlements, !entitlementsText.isEmpty {
            let tempEntitlements = extracted.extractionRoot.appendingPathComponent("entitlements.plist")
            try entitlementsText.write(to: tempEntitlements, atomically: true, encoding: .utf8)
            entitlementsURL = tempEntitlements
        }

        let dylibURLs = try prepareTweaks(
            ids: job.options.injectedDylibIDs,
            stagingFolder: extracted.extractionRoot.appendingPathComponent("Tweaks", isDirectory: true)
        )

        var iconURL: URL?
        if let iconPath = job.options.customIconPath {
            iconURL = URL(fileURLWithPath: iconPath)
        }

        await MainActor.run { job.status = .signing }
        let originalBundleID = try IPAService.metadata(from: extracted).bundleIdentifier
        let resolvedBundleID = job.options.resolvedBundleIdentifier(original: originalBundleID, certificateBundleID: certificateBundleID)

        _ = try ZSignEngine.sign(
            extractionRoot: extracted.extractionRoot,
            p12URL: p12URL,
            p12Password: password,
            provisionURL: provisionURL,
            entitlementsURL: entitlementsURL,
            bundleIdentifier: resolvedBundleID,
            bundleName: job.options.displayName.isEmpty ? nil : job.options.displayName,
            bundleVersion: job.options.version.isEmpty ? nil : job.options.version,
            minimumOSVersion: job.options.minimumOSVersion.isEmpty ? nil : job.options.minimumOSVersion,
            iconURL: iconURL,
            dylibURLs: dylibURLs,
            removedDylibNames: [],
            removeExtensions: job.options.removePlugins,
            removeWatchApp: job.options.removeWatchApp,
            removeUISupportedDevices: job.options.removeDeviceRestrictions,
            removeProvisionAfterSigning: job.options.removeProvisioningProfile,
            weakInject: job.options.weakInjection,
            injectIntoExtensions: job.options.injectIntoExtensions,
            forceSign: job.options.stripExistingSignature
        )

        await MainActor.run { job.status = .packaging }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).ipa")
        try IPAService.repack(extracted: extracted, to: output, compress: !job.options.fastPackaging)

        if let cacheKey {
            cache.store(key: cacheKey, ipaURL: output)
        }

        let elapsed = Date().timeIntervalSince(started)
        await MainActor.run { job.status = .done(elapsed) }
        return (output, resolvedBundleID)
    }

    /// Returns the files zsign should inject. Tweaks built for a jailbreak link
    /// CydiaSubstrate from a path that doesn't exist in a sideloaded app, so a
    /// copy of each such tweak is pointed at the substrate provider from the
    /// Tweak Library, which gets injected alongside it.
    private func prepareTweaks(ids: [UUID], stagingFolder: URL) throws -> [URL] {
        let store = DylibLibraryStore.shared
        let selected = ids.compactMap { id in store.dylibs.first { $0.id == id } }
        guard !selected.isEmpty else { return [] }

        let provider = store.substrateProvider
        var urls: [URL] = []
        var needsProvider = selected.contains { $0.isSubstrateProvider }

        for dylib in selected where !dylib.isSubstrateProvider {
            let source = store.url(for: dylib)
            guard MachOPatcher.linkedLibraries(at: source).contains(where: TweakDependencies.isSubstrate) else {
                urls.append(source)
                continue
            }
            guard let provider else { throw SigningEngineError.substrateMissing(dylib.displayName) }

            try FileManager.default.createDirectory(at: stagingFolder, withIntermediateDirectories: true)
            let staged = stagingFolder.appendingPathComponent(source.lastPathComponent)
            try? FileManager.default.removeItem(at: staged)
            try FileManager.default.copyItem(at: source, to: staged)
            // zsign copies every injected file next to the main executable, so
            // the provider sits right beside the tweak.
            try MachOPatcher.rewriteLinkedLibraries(
                at: staged,
                matching: TweakDependencies.isSubstrate,
                to: "@loader_path/" + store.url(for: provider).lastPathComponent
            )
            urls.append(staged)
            needsProvider = true
        }

        if needsProvider, let provider {
            // Load the provider first so it's in place before any tweak runs.
            urls.insert(store.url(for: provider), at: 0)
        }
        return urls
    }
}
