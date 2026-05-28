import Foundation
import ZIPFoundation

public enum KMZArchiveError: Error, Equatable {
    case notAZipArchive
    case noKMLEntry
    /// The archive declares (or, mid-extraction, produces) more entries or uncompressed
    /// bytes than the allowed limit — a guard against decompression-bomb inputs.
    case archiveTooLarge
}

public struct KMZContents: Sendable {
    /// Raw bytes of the root KML document.
    public let rootKML: Data
    /// Archive-relative path of the root KML entry (e.g. "doc.kml").
    /// Phase 2 uses this to resolve resource hrefs that are relative to the root KML's location.
    public let rootKMLPath: String
    /// All other archive entries, keyed by archive path (e.g. "images/icon-1.png").
    public let resources: [String: Data]
}

public enum KMZArchive {
    /// True if the data begins with the local-file-header zip magic number `PK\x03\x04`.
    public static func isKMZ(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let s = data.startIndex
        return data[s] == 0x50 && data[s + 1] == 0x4B && data[s + 2] == 0x03 && data[s + 3] == 0x04
    }

    /// Generous defaults that no realistic KML/KMZ (even photo-heavy) approaches, but that
    /// stop a crafted decompression bomb from exhausting memory. Callers may tighten them.
    public static let defaultMaxEntryCount = 100_000
    public static let defaultMaxUncompressedBytes = 2 * 1024 * 1024 * 1024 // 2 GiB

    public static func extract(
        _ data: Data,
        maxEntryCount: Int = defaultMaxEntryCount,
        maxUncompressedBytes: Int = defaultMaxUncompressedBytes
    ) throws -> KMZContents {
        guard isKMZ(data) else { throw KMZArchiveError.notAZipArchive }
        let archive = try Archive(data: data, accessMode: .read)

        // Pre-flight on the declared sizes: cheaply reject a pathological archive before
        // allocating anything for it.
        var fileEntries: [Entry] = []
        var declaredTotal = 0
        for entry in archive where entry.type == .file {
            fileEntries.append(entry)
            if fileEntries.count > maxEntryCount { throw KMZArchiveError.archiveTooLarge }
            declaredTotal &+= Int(clamping: entry.uncompressedSize)
            if declaredTotal < 0 || declaredTotal > maxUncompressedBytes {
                throw KMZArchiveError.archiveTooLarge
            }
        }

        var entries: [String: Data] = [:]
        var extractedTotal = 0
        for entry in fileEntries {
            var bytes = Data()
            // Enforce the byte budget during extraction too, so a lying header can't balloon
            // memory before the post-loop check fires.
            _ = try archive.extract(entry) { chunk in
                extractedTotal &+= chunk.count
                guard extractedTotal >= 0, extractedTotal <= maxUncompressedBytes else {
                    throw KMZArchiveError.archiveTooLarge
                }
                bytes.append(chunk)
            }
            entries[entry.path] = bytes
        }

        guard let rootPath = chooseRootKML(from: Array(entries.keys)) else {
            throw KMZArchiveError.noKMLEntry
        }
        let rootKML = entries.removeValue(forKey: rootPath)!
        return KMZContents(rootKML: rootKML, rootKMLPath: rootPath, resources: entries)
    }

    /// Prefers a top-level `doc.kml`, otherwise the first top-level `.kml`, otherwise any `.kml`.
    static func chooseRootKML(from paths: [String]) -> String? {
        let kmlPaths = paths.filter { $0.lowercased().hasSuffix(".kml") }
        if let doc = kmlPaths.first(where: { $0.caseInsensitiveCompare("doc.kml") == .orderedSame }) {
            return doc
        }
        if let topLevel = kmlPaths.filter({ !$0.contains("/") }).sorted().first { return topLevel }
        return kmlPaths.sorted().first
    }
}
