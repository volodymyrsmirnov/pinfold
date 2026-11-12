import Foundation
import ZIPFoundation

public enum KMZArchiveError: Error, Equatable {
    case notAZipArchive
    case noKMLEntry
    /// The archive declares (or, mid-extraction, produces) more entries or uncompressed
    /// bytes than the allowed limit — a guard against decompression-bomb inputs.
    case archiveTooLarge
    /// The data starts like a zip but the archive could not be read (truncated, damaged,
    /// unsupported). `detail` is the underlying ZIPFoundation error, described.
    case corruptArchive(detail: String)
}

extension KMZArchiveError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notAZipArchive:
            "This file is not a readable zip archive."
        case .noKMLEntry:
            "This KMZ has no KML inside."
        case .archiveTooLarge:
            "This KMZ is too large to open."
        case let .corruptArchive(detail):
            "This KMZ is damaged and can't be read (\(detail))."
        }
    }
}

public struct KMZContents: Sendable {
    /// Raw bytes of the root KML document.
    public let rootKML: Data
    /// Archive-relative path of the root KML entry (e.g. "doc.kml").
    /// Phase 2 uses this to resolve resource hrefs that are relative to the root KML's location.
    public let rootKMLPath: String
    /// All other archive entries, keyed by archive path (e.g. "images/icon-1.png").
    ///
    /// Keys are guaranteed traversal-safe: never absolute, never containing `.` or `..`
    /// components. The app joins these keys onto a destination directory and writes the
    /// bytes there, so this guarantee is load-bearing — entries whose declared path is
    /// absolute or escapes the extraction root are silently dropped during extraction.
    public let resources: [String: Data]
}

public enum KMZArchive {
    /// True if the data begins with the local-file-header zip magic number `PK\x03\x04`.
    public static func isKMZ(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let s = data.startIndex
        return data[s] == 0x50 && data[s + 1] == 0x4B && data[s + 2] == 0x03 && data[s + 3] == 0x04
    }

    /// Defaults that no realistic KML/KMZ approaches, but that stop a crafted
    /// decompression bomb from exhausting memory. Callers may tighten them.
    public static let defaultMaxEntryCount = 100_000
    /// Cap on total uncompressed bytes held in memory (`extract`) and on the root KML.
    public static let defaultMaxUncompressedBytes = 256 * 1024 * 1024 // 256 MiB
    /// Cap on total uncompressed bytes streamed to disk (`extractResources`).
    public static let defaultMaxStreamedBytes = 1024 * 1024 * 1024 // 1 GiB

    /// Inflates everything into memory. Prefer `extractRoot` plus `extractResources` for
    /// large archives; this stays for `KMLReader.read(data:)`.
    public static func extract(
        _ data: Data,
        maxEntryCount: Int = defaultMaxEntryCount,
        maxUncompressedBytes: Int = defaultMaxUncompressedBytes
    ) throws -> KMZContents {
        try wrappingZipErrors {
            let archive = try openArchive(data)
            let fileEntries = try safeFileEntries(archive, maxEntryCount: maxEntryCount,
                                                  maxDeclaredBytes: maxUncompressedBytes)
            var entries: [String: Data] = [:]
            var extractedTotal = 0
            for (entry, safePath) in fileEntries {
                var bytes = Data()
                // Enforce the byte budget during extraction too: zip headers can lie about
                // uncompressed sizes, so this streaming check is the real
                // decompression-bomb defense and must not be removed.
                _ = try archive.extract(entry) { chunk in
                    extractedTotal &+= chunk.count
                    guard extractedTotal >= 0, extractedTotal <= maxUncompressedBytes else {
                        throw KMZArchiveError.archiveTooLarge
                    }
                    bytes.append(chunk)
                }
                entries[safePath] = bytes
            }
            guard let rootPath = chooseRootKML(from: Array(entries.keys)) else {
                throw KMZArchiveError.noKMLEntry
            }
            let rootKML = entries.removeValue(forKey: rootPath)!
            return KMZContents(rootKML: rootKML, rootKMLPath: rootPath, resources: entries)
        }
    }

    /// Inflates only the root KML. The root is chosen from entry names, so resources are
    /// never inflated and do not count against the budget.
    public static func extractRoot(
        _ data: Data,
        maxEntryCount: Int = defaultMaxEntryCount,
        maxRootBytes: Int = defaultMaxUncompressedBytes
    ) throws -> (rootKML: Data, rootKMLPath: String) {
        try wrappingZipErrors {
            let archive = try openArchive(data)
            let fileEntries = try safeFileEntries(archive, maxEntryCount: maxEntryCount,
                                                  maxDeclaredBytes: nil)
            guard let rootPath = chooseRootKML(from: fileEntries.map(\.path)),
                  let root = fileEntries.first(where: { $0.path == rootPath })
            else { throw KMZArchiveError.noKMLEntry }
            if Int(clamping: root.entry.uncompressedSize) > maxRootBytes {
                throw KMZArchiveError.archiveTooLarge
            }
            var bytes = Data()
            _ = try archive.extract(root.entry) { chunk in
                guard bytes.count + chunk.count <= maxRootBytes else {
                    throw KMZArchiveError.archiveTooLarge
                }
                bytes.append(chunk)
            }
            return (bytes, rootPath)
        }
    }

    /// Streams every non-root entry to `directory`, one file per entry, and returns
    /// root-relative key -> written filename. Keys match hrefs as written in the root KML
    /// (see `rootRelativeKey`). `filenameFor` maps a key to a flat filename; a result that is
    /// empty or contains a path separator or dot-segment is skipped. Entries with unsafe
    /// archive paths are skipped. Nothing larger than `maxUncompressedBytes` in total is
    /// written. On any throw (overflow included) every file written by this call is removed
    /// again, so the directory is left as it was found; files already there are untouched.
    public static func extractResources(
        _ data: Data,
        into directory: URL,
        filenameFor: (String) -> String,
        maxEntryCount: Int = defaultMaxEntryCount,
        maxUncompressedBytes: Int = defaultMaxStreamedBytes
    ) throws -> [String: String] {
        try wrappingZipErrors {
            let archive = try openArchive(data)
            let fileEntries = try safeFileEntries(archive, maxEntryCount: maxEntryCount,
                                                  maxDeclaredBytes: nil)
            guard let rootPath = chooseRootKML(from: fileEntries.map(\.path)) else {
                throw KMZArchiveError.noKMLEntry
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var written: [String: String] = [:]
            var total = 0
            do {
                for (entry, safePath) in fileEntries where safePath != rootPath {
                    let key = rootRelativeKey(safePath, rootKMLPath: rootPath)
                    let name = filenameFor(key)
                    guard isFlatFilename(name) else { continue }
                    let target = directory.appendingPathComponent(name)
                    try streamEntry(entry, of: archive, to: target, total: &total, limit: maxUncompressedBytes)
                    written[key] = name
                }
            } catch {
                for name in written.values {
                    try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
                }
                throw error
            }
            return written
        }
    }

    /// Re-keys an archive path relative to the root KML's directory (`folder/icons/a.png`
    /// with root `folder/doc.kml` becomes `icons/a.png`). Paths outside that directory keep
    /// their raw archive path. Stripping a prefix cannot introduce `..`.
    static func rootRelativeKey(_ path: String, rootKMLPath: String) -> String {
        guard let slash = rootKMLPath.lastIndex(of: "/") else { return path }
        let prefix = String(rootKMLPath[...slash])
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    private static func isFlatFilename(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    private static func streamEntry(
        _ entry: Entry, of archive: Archive, to target: URL, total: inout Int, limit: Int
    ) throws {
        let fileManager = FileManager.default
        fileManager.createFile(atPath: target.path, contents: nil)
        let handle = try FileHandle(forWritingTo: target)
        var running = total
        do {
            defer { try? handle.close() }
            _ = try archive.extract(entry) { chunk in
                running &+= chunk.count
                guard running >= 0, running <= limit else { throw KMZArchiveError.archiveTooLarge }
                try handle.write(contentsOf: chunk)
            }
        } catch {
            try? fileManager.removeItem(at: target)
            throw error
        }
        total = running
    }

    private static func openArchive(_ data: Data) throws -> Archive {
        guard isKMZ(data) else { throw KMZArchiveError.notAZipArchive }
        return try Archive(data: data, accessMode: .read)
    }

    /// Runs `body`, converting any non-`KMZArchiveError` (ZIPFoundation, I/O) into
    /// `corruptArchive`. File-system errors while writing also land here with their detail.
    private static func wrappingZipErrors<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as KMZArchiveError {
            throw error
        } catch {
            throw KMZArchiveError.corruptArchive(detail: String(describing: error))
        }
    }

    /// Lists file entries with traversal-safe paths, applying the entry-count cap and (when
    /// given) the declared-size pre-flight. Reads the central directory only; nothing is inflated.
    private static func safeFileEntries(
        _ archive: Archive, maxEntryCount: Int, maxDeclaredBytes: Int?
    ) throws -> [(entry: Entry, path: String)] {
        var result: [(entry: Entry, path: String)] = []
        var count = 0
        var declaredTotal = 0
        for entry in archive where entry.type == .file {
            count += 1
            if count > maxEntryCount {
                throw KMZArchiveError.archiveTooLarge
            }
            if let maxDeclaredBytes {
                declaredTotal &+= Int(clamping: entry.uncompressedSize)
                if declaredTotal < 0 || declaredTotal > maxDeclaredBytes {
                    throw KMZArchiveError.archiveTooLarge
                }
            }
            // Drop entries whose declared path is absolute or escapes the extraction root.
            if let safe = sanitizedArchivePath(entry.path) {
                result.append((entry, safe))
            }
        }
        return result
    }

    /// Returns a traversal-safe form of a raw archive entry path, or nil if the path must
    /// be rejected outright. Absolute paths and paths containing a `..` component return
    /// nil; `.` components and empty components (`//`) are dropped; the remainder is
    /// re-joined with `/`.
    private static func sanitizedArchivePath(_ raw: String) -> String? {
        guard !raw.hasPrefix("/") else { return nil }
        var kept: [Substring] = []
        for component in raw.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." {
                continue
            }
            if component == ".." {
                return nil
            }
            kept.append(component)
        }
        guard !kept.isEmpty else { return nil }
        return kept.joined(separator: "/")
    }

    /// Prefers a top-level `doc.kml`, otherwise the first top-level `.kml`, otherwise any `.kml`.
    static func chooseRootKML(from paths: [String]) -> String? {
        let kmlPaths = paths.filter { $0.lowercased().hasSuffix(".kml") }
        if let doc = kmlPaths.first(where: { $0.caseInsensitiveCompare("doc.kml") == .orderedSame }) {
            return doc
        }
        if let topLevel = kmlPaths.filter({ !$0.contains("/") }).sorted().first {
            return topLevel
        }
        return kmlPaths.sorted().first
    }
}
