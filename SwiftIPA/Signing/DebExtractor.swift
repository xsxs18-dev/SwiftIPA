import Foundation
import Compression

enum DebExtractorError: LocalizedError {
    case notADeb
    case unsupportedCompression(String)
    case noDylibFound
    case corruptArchive

    var errorDescription: String? {
        switch self {
        case .notADeb:
            return String(localized: "This isn't a valid .deb package.")
        case .unsupportedCompression(let name):
            return String(localized: "This .deb uses \(name) compression, which SwiftIPA can't unpack yet. Re-export it as a raw .dylib instead.")
        case .noDylibFound:
            return String(localized: "No .dylib was found inside this .deb package.")
        case .corruptArchive:
            return String(localized: "This .deb package looks corrupted.")
        }
    }
}

/// A Mach-O file pulled out of a .deb package.
struct DebBinary {
    /// Path inside the package, e.g. `Library/MobileSubstrate/DynamicLibraries/Tweak.dylib`.
    var packagePath: String
    var url: URL

    var fileName: String { (packagePath as NSString).lastPathComponent }
}

enum DebExtractor {
    /// Unpacks every injectable Mach-O (`.dylib` files, plus a bare `CydiaSubstrate`
    /// binary) from the package's data archive into `destinationFolder`.
    static func extractBinaries(from debURL: URL, into destinationFolder: URL) throws -> [DebBinary] {
        let tarData = try dataArchive(from: debURL)
        let entries = readTar(tarData).filter { entry in
            let name = (entry.name as NSString).lastPathComponent
            guard name.lowercased().hasSuffix(".dylib") || name == "CydiaSubstrate" else { return false }
            return isMachO(entry.data)
        }
        guard !entries.isEmpty else { throw DebExtractorError.noDylibFound }

        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)

        var results: [DebBinary] = []
        var usedNames = Set<String>()
        for entry in entries {
            var fileName = (entry.name as NSString).lastPathComponent
            // A bare framework binary has no extension, give it one so zsign's
            // copy lands next to the tweaks as a normal dylib.
            if !fileName.lowercased().hasSuffix(".dylib") { fileName += ".dylib" }
            var candidate = fileName
            var attempt = 1
            while usedNames.contains(candidate.lowercased()) {
                candidate = "\((fileName as NSString).deletingPathExtension)-\(attempt).dylib"
                attempt += 1
            }
            usedNames.insert(candidate.lowercased())

            let destination = destinationFolder.appendingPathComponent(candidate)
            try? FileManager.default.removeItem(at: destination)
            try entry.data.write(to: destination)
            results.append(DebBinary(packagePath: entry.name, url: destination))
        }
        return results
    }

    // MARK: - ar

    private static func dataArchive(from debURL: URL) throws -> Data {
        let data = try Data(contentsOf: debURL, options: .mappedIfSafe)
        guard data.count > 8, data.prefix(8).elementsEqual(Array("!<arch>\n".utf8)) else {
            throw DebExtractorError.notADeb
        }

        var cursor = 8
        var dataMember: (name: String, payload: Data)?

        while cursor + 60 <= data.count {
            let header = data.subdata(in: cursor..<(cursor + 60))
            guard var name = string(header, range: 0..<16)?.trimmingCharacters(in: .whitespaces) else {
                throw DebExtractorError.corruptArchive
            }
            // GNU ar terminates member names with a slash.
            if name.hasSuffix("/") { name.removeLast() }
            guard let sizeString = string(header, range: 48..<58)?.trimmingCharacters(in: .whitespaces),
                  let size = Int(sizeString) else {
                throw DebExtractorError.corruptArchive
            }

            let payloadStart = cursor + 60
            guard payloadStart + size <= data.count else { throw DebExtractorError.corruptArchive }

            if name.hasPrefix("data.tar") {
                dataMember = (name, data.subdata(in: payloadStart..<(payloadStart + size)))
                break
            }

            var next = payloadStart + size
            if next % 2 == 1 { next += 1 }
            cursor = next
        }

        guard let member = dataMember else { throw DebExtractorError.corruptArchive }

        switch member.name {
        case "data.tar":
            return member.payload
        case "data.tar.gz":
            return try inflateGzip(member.payload)
        case "data.tar.xz":
            // Apple's LZMA decoder reads the xz container format.
            return try decompress(member.payload, algorithm: COMPRESSION_LZMA)
        case "data.tar.lzma":
            throw DebExtractorError.unsupportedCompression("lzma")
        case "data.tar.zst":
            throw DebExtractorError.unsupportedCompression("zstd")
        case "data.tar.bz2":
            throw DebExtractorError.unsupportedCompression("bzip2")
        default:
            throw DebExtractorError.unsupportedCompression(member.name)
        }
    }

    private static func string(_ data: Data, range: Range<Int>) -> String? {
        guard range.upperBound <= data.count else { return nil }
        return String(data: data.subdata(in: range), encoding: .ascii)
    }

    private static func isMachO(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let magic = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
        return [MachO.fatMagic, MachO.fatCigam, MachO.fatMagic64, MachO.fatCigam64,
                MachO.magic64, MachO.cigam64, MachO.magic32, MachO.cigam32].contains(magic)
    }

    // MARK: - Decompression

    private static func inflateGzip(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1F, bytes[1] == 0x8B else { throw DebExtractorError.corruptArchive }
        var offset = 10
        let flags = bytes[3]
        if flags & 0x04 != 0, offset + 2 <= bytes.count {
            let extraLength = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
            offset += 2 + extraLength
        }
        if flags & 0x08 != 0 {
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x10 != 0 {
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 {
            offset += 2
        }

        guard offset < bytes.count - 8 else { throw DebExtractorError.corruptArchive }
        // COMPRESSION_ZLIB is raw deflate, which is what sits between the gzip header and trailer.
        return try decompress(Data(bytes[offset..<(bytes.count - 8)]), algorithm: COMPRESSION_ZLIB)
    }

    /// Streams through the input so the output size doesn't need to be known up front.
    private static func decompress(_ input: Data, algorithm: compression_algorithm) throws -> Data {
        let chunkSize = 1 << 20
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { destination.deallocate() }

        var stream = compression_stream(
            dst_ptr: destination, dst_size: 0,
            src_ptr: UnsafePointer(destination), src_size: 0,
            state: nil
        )
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, algorithm) == COMPRESSION_STATUS_OK else {
            throw DebExtractorError.corruptArchive
        }
        defer { compression_stream_destroy(&stream) }

        var output = Data()
        let status: compression_status = input.withUnsafeBytes { raw -> compression_status in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return COMPRESSION_STATUS_ERROR }
            stream.src_ptr = base
            stream.src_size = input.count

            while true {
                stream.dst_ptr = destination
                stream.dst_size = chunkSize
                let result = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                output.append(destination, count: chunkSize - stream.dst_size)
                if result != COMPRESSION_STATUS_OK { return result }
                // All input consumed and nothing produced without reaching the end: truncated.
                if stream.src_size == 0 && stream.dst_size == chunkSize { return COMPRESSION_STATUS_ERROR }
            }
        }

        guard status == COMPRESSION_STATUS_END, !output.isEmpty else { throw DebExtractorError.corruptArchive }
        return output
    }

    // MARK: - tar

    private struct TarEntry {
        var name: String
        var data: Data
    }

    private static func readTar(_ data: Data) -> [TarEntry] {
        var entries: [TarEntry] = []
        var cursor = 0
        var pendingLongName: String?

        while cursor + 512 <= data.count {
            let block = data.subdata(in: cursor..<(cursor + 512))
            if block.allSatisfy({ $0 == 0 }) { break }

            guard let sizeOctal = string(block, range: 124..<136)?
                .trimmingCharacters(in: CharacterSet(charactersIn: " \0")),
                  let size = Int(sizeOctal.isEmpty ? "0" : sizeOctal, radix: 8) else {
                break
            }

            let typeFlag = block[block.startIndex + 156]
            let fileStart = cursor + 512
            let paddedSize = ((size + 511) / 512) * 512
            guard fileStart + size <= data.count else { break }
            let content = data.subdata(in: fileStart..<(fileStart + size))

            switch typeFlag {
            case UInt8(ascii: "L"):
                // GNU long name for the next entry.
                pendingLongName = cString(content)
            case UInt8(ascii: "x"):
                // pax header, only the path matters here.
                pendingLongName = paxPath(content) ?? pendingLongName
            case UInt8(ascii: "0"), 0:
                var name = pendingLongName ?? headerName(block)
                if name.hasPrefix("./") { name.removeFirst(2) }
                if !name.isEmpty {
                    entries.append(TarEntry(name: name, data: content))
                }
                pendingLongName = nil
            default:
                pendingLongName = nil
            }

            cursor = fileStart + paddedSize
        }

        return entries
    }

    private static func headerName(_ block: Data) -> String {
        let name = cString(block.subdata(in: 0..<100))
        // POSIX ustar keeps long paths split into a prefix field. Old GNU tar
        // ("ustar  ") uses those bytes for other things, so skip it there.
        if string(block, range: 257..<263) == "ustar\0" {
            let prefix = cString(block.subdata(in: 345..<500))
            if !prefix.isEmpty { return prefix + "/" + name }
        }
        return name
    }

    private static func cString(_ data: Data) -> String {
        let bytes = data.prefix { $0 != 0 }
        return String(data: bytes, encoding: .utf8) ?? String(decoding: bytes, as: UTF8.self)
    }

    private static func paxPath(_ data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n") {
            guard let space = line.firstIndex(of: " ") else { continue }
            let record = line[line.index(after: space)...]
            if record.hasPrefix("path=") {
                return String(record.dropFirst(5))
            }
        }
        return nil
    }
}
