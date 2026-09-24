import Foundation
import Combine
import SwiftUI

final class DylibLibraryStore: ObservableObject {
    static let shared = DylibLibraryStore()

    @Published private(set) var dylibs: [InjectedDylib] = []
    @Published private(set) var analyses: [UUID: TweakAnalysis] = [:]

    private let folder: URL
    private let indexURL: URL

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        folder = documents.appendingPathComponent("Tweaks", isDirectory: true)
        indexURL = documents.appendingPathComponent("tweaks-index.json")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        dylibs = load()
        for dylib in dylibs where !dylib.isSubstrateProvider {
            analyses[dylib.id] = Self.analyze(url(for: dylib))
        }
    }

    func url(for dylib: InjectedDylib) -> URL {
        folder.appendingPathComponent(dylib.fileName)
    }

    /// The tweak that provides CydiaSubstrate / ElleKit to the others, if one was imported.
    var substrateProvider: InjectedDylib? {
        dylibs.first { $0.isSubstrateProvider }
    }

    func analysis(for dylib: InjectedDylib) -> TweakAnalysis {
        if let cached = analyses[dylib.id] { return cached }
        return Self.analyze(url(for: dylib))
    }

    /// Imports a .dylib, or every dylib inside a .deb. A .deb that ships
    /// ElleKit or CydiaSubstrate is imported as the substrate provider instead.
    @discardableResult
    func importFile(at sourceURL: URL, displayName: String? = nil) async throws -> [InjectedDylib] {
        let folder = folder
        let packageName = displayName ?? sourceURL.deletingPathExtension().lastPathComponent
        let isDeb = sourceURL.pathExtension.lowercased() == "deb"

        let imported = try await Task.detached(priority: .userInitiated) { () -> [(url: URL, name: String, isProvider: Bool)] in
            let fileManager = FileManager.default
            let needsAccess = sourceURL.startAccessingSecurityScopedResource()
            defer { if needsAccess { sourceURL.stopAccessingSecurityScopedResource() } }

            guard isDeb else {
                let destinationName = Self.uniqueFileName(for: sourceURL.lastPathComponent, in: folder)
                let destination = folder.appendingPathComponent(destinationName)
                try fileManager.copyItem(at: sourceURL, to: destination)
                return [(destination, packageName, Self.isProviderFileName(destination.lastPathComponent))]
            }

            let staging = fileManager.temporaryDirectory.appendingPathComponent("deb-\(UUID().uuidString)", isDirectory: true)
            defer { try? fileManager.removeItem(at: staging) }
            let binaries = try DebExtractor.extractBinaries(from: sourceURL, into: staging)

            // ElleKit and Substrate packages ship several shims that all end up at
            // the same hooking code, keep only the one that works on its own.
            if let provider = Self.bestProvider(in: binaries) {
                let destination = folder.appendingPathComponent(Self.uniqueFileName(for: provider.fileName, in: folder))
                try fileManager.moveItem(at: provider.url, to: destination)
                return [(destination, packageName, true)]
            }

            // Tweaks live in DynamicLibraries; anything else is a helper library.
            let tweaks = binaries.filter { $0.packagePath.contains("DynamicLibraries/") }
            let chosen = tweaks.isEmpty ? binaries : tweaks
            return try chosen.map { binary -> (url: URL, name: String, isProvider: Bool) in
                let destination = folder.appendingPathComponent(Self.uniqueFileName(for: binary.fileName, in: folder))
                try fileManager.moveItem(at: binary.url, to: destination)
                let stem = (binary.fileName as NSString).deletingPathExtension
                let name = chosen.count == 1 ? packageName : "\(packageName) · \(stem)"
                return (destination, name, false)
            }
        }.value

        let entries = imported.map { item -> InjectedDylib in
            let size = (try? FileManager.default.attributesOfItem(atPath: item.url.path)[.size] as? Int64) ?? 0
            return InjectedDylib(
                fileName: item.url.lastPathComponent,
                displayName: item.name,
                byteSize: size,
                packageName: isDeb ? packageName : nil,
                isSubstrateProvider: item.isProvider
            )
        }
        let newAnalyses = Dictionary(uniqueKeysWithValues: zip(entries.map(\.id), imported.map { Self.analyze($0.url) }))

        await MainActor.run {
            if entries.contains(where: \.isSubstrateProvider) {
                for index in dylibs.indices { dylibs[index].isSubstrateProvider = false }
            }
            analyses.merge(newAnalyses) { _, new in new }
            withAnimation(.easeOut(duration: 0.25)) {
                dylibs.append(contentsOf: entries)
            }
            persist()
        }
        return entries
    }

    /// Only one tweak can provide substrate at a time.
    func setSubstrateProvider(_ dylib: InjectedDylib, enabled: Bool) {
        for index in dylibs.indices {
            dylibs[index].isSubstrateProvider = enabled && dylibs[index].id == dylib.id
        }
        persist()
    }

    private static func isProviderFileName(_ name: String) -> Bool {
        ["libellekit.dylib", "cydiasubstrate.dylib", "cydiasubstrate", "libsubstrate.dylib"].contains(name.lowercased())
    }

    private static func bestProvider(in binaries: [DebBinary]) -> DebBinary? {
        // libsubstrate.dylib in ElleKit is only a re-export of libellekit.dylib.
        let order = ["libellekit.dylib", "cydiasubstrate.dylib", "libsubstrate.dylib"]
        for name in order {
            if let match = binaries.first(where: { $0.fileName.lowercased() == name }) { return match }
        }
        return nil
    }

    private static func analyze(_ url: URL) -> TweakAnalysis {
        let libraries = MachOPatcher.linkedLibraries(at: url)
        return TweakAnalysis(
            needsSubstrate: libraries.contains(where: TweakDependencies.isSubstrate),
            jailbreakOnlyLibraries: libraries.filter(TweakDependencies.isJailbreakOnly)
        )
    }

    func remove(_ dylib: InjectedDylib) {
        try? FileManager.default.removeItem(at: url(for: dylib))
        analyses[dylib.id] = nil
        withAnimation(.easeOut(duration: 0.25)) {
            dylibs.removeAll { $0.id == dylib.id }
        }
        persist()
    }

    func rename(_ dylib: InjectedDylib, to newDisplayName: String) {
        guard let index = dylibs.firstIndex(where: { $0.id == dylib.id }) else { return }
        dylibs[index].displayName = newDisplayName
        persist()
    }

    func removeAll() {
        for dylib in dylibs {
            try? FileManager.default.removeItem(at: url(for: dylib))
        }
        withAnimation(.easeOut(duration: 0.25)) {
            dylibs.removeAll()
        }
        persist()
    }

    private static func uniqueFileName(for name: String, in folder: URL) -> String {
        var candidate = name
        var attempt = 1
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate).path) {
            let stem = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            candidate = "\(stem)-\(attempt).\(ext)"
            attempt += 1
        }
        return candidate
    }

    private func load() -> [InjectedDylib] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        return (try? JSONDecoder().decode([InjectedDylib].self, from: data)) ?? []
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(dylibs) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
