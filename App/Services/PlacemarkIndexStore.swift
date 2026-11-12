import Foundation

// MARK: - PlacemarkIndexStore

/// An in-memory cache of decoded placemark indexes and note sidecars (B17).
///
/// Catalogue search runs on every debounced keystroke; without this it would re-read and
/// re-decode every entry's index each time. Indexes are cached by resources directory and
/// validated by the index file's modification date and size; notes are cached by sidecar
/// URL and validated the same way. Text is folded once per file change, so a keystroke is a
/// substring test per placemark.
///
/// Lock-guarded (not an actor) so the synchronous, off-main `PlacemarkIndex.search` can use it.
final class PlacemarkIndexStore: @unchecked Sendable {
    /// The process-wide store used by default.
    static let shared = PlacemarkIndexStore()

    /// A decoded index plus its folded search forms (parallel to `entries`).
    struct Snapshot {
        let entries: [PlacemarkIndex.Entry]
        let foldedNames: [String]
        let foldedTexts: [String?]
    }

    /// One live (non-tombstone) note: original text for snippets, folded text for matching.
    struct NoteText {
        let text: String
        let folded: String
    }

    /// The search-relevant slice of an entry's sidecar.
    struct NotesSnapshot {
        let isTrashed: Bool
        let notes: [String: NoteText]

        static let empty = NotesSnapshot(isTrashed: false, notes: [:])
    }

    private struct Stamp: Equatable {
        let file: String
        let modified: Date
        let size: Int
    }

    private let lock = NSLock()
    private var indexes: [String: (stamp: Stamp, snapshot: Snapshot)] = [:]
    private var sidecars: [String: (stamp: Stamp, snapshot: NotesSnapshot)] = [:]
    private var decodes = 0
    private var noteDecodes = 0

    /// How many index files have been decoded (for tests).
    var decodeCount: Int {
        lock.withLock { decodes }
    }

    /// How many sidecars have been decoded (for tests).
    var notesDecodeCount: Int {
        lock.withLock { noteDecodes }
    }

    /// How many indexes are currently cached (for tests).
    var cachedIndexCount: Int {
        lock.withLock { indexes.count }
    }

    // MARK: - Indexes

    /// The decoded index in `resourcesDir` (v2, else v1), reusing the cached decode while the
    /// file is unchanged. `nil` (and the cache entry dropped) when there is no readable index.
    func snapshot(for resourcesDir: URL) -> Snapshot? {
        let key = resourcesDir.path
        guard let stamp = Self.indexStamp(in: resourcesDir) else {
            lock.withLock { _ = indexes.removeValue(forKey: key) }
            return nil
        }
        if let cached = lock.withLock({ indexes[key] }), cached.stamp == stamp {
            return cached.snapshot
        }
        guard let entries = PlacemarkIndex.read(from: resourcesDir) else {
            lock.withLock { _ = indexes.removeValue(forKey: key) }
            return nil
        }
        let snapshot = Snapshot(
            entries: entries,
            foldedNames: entries.map { SearchText.fold($0.name) },
            foldedTexts: entries.map { $0.text.map(SearchText.fold) }
        )
        lock.withLock {
            indexes[key] = (stamp, snapshot)
            decodes += 1
        }
        return snapshot
    }

    private static func indexStamp(in dir: URL) -> Stamp? {
        for name in [PlacemarkIndex.filename, PlacemarkIndex.legacyFilename] {
            if let stamp = stamp(of: dir.appendingPathComponent(name)) {
                return stamp
            }
        }
        return nil
    }

    private static func stamp(of file: URL) -> Stamp? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let modified = attrs[.modificationDate] as? Date
        else { return nil }
        return Stamp(file: file.lastPathComponent, modified: modified, size: (attrs[.size] as? Int) ?? 0)
    }

    // MARK: - Notes

    /// The trash flag and live notes of the sidecar at `url`, cached by modification date and
    /// size. A missing or unreadable sidecar yields `.empty` (not trashed, no notes).
    func notes(at url: URL) -> NotesSnapshot {
        let key = url.path
        guard let stamp = Self.stamp(of: url) else {
            lock.withLock { _ = sidecars.removeValue(forKey: key) }
            return .empty
        }
        if let cached = lock.withLock({ sidecars[key] }), cached.stamp == stamp {
            return cached.snapshot
        }
        guard let data = try? Data(contentsOf: url),
              let metadata = try? EntryMetadata.decoded(from: data)
        else { return .empty }
        var live: [String: NoteText] = [:]
        for (noteKey, note) in metadata.notes where !note.isTombstone {
            live[noteKey] = NoteText(text: note.text, folded: SearchText.fold(note.text))
        }
        let snapshot = NotesSnapshot(isTrashed: metadata.trashedAt != nil, notes: live)
        lock.withLock {
            sidecars[key] = (stamp, snapshot)
            noteDecodes += 1
        }
        return snapshot
    }

    // MARK: - Pruning

    /// Drops cached indexes and sidecars whose resources directory / sidecar is not in the
    /// given sets (entries removed from the catalogue).
    func prune(keeping resourcesDirs: Set<URL>, sidecars keptSidecars: Set<URL> = []) {
        let keptIndexes = Set(resourcesDirs.map(\.path))
        let keptNotes = Set(keptSidecars.map(\.path))
        lock.withLock {
            indexes = indexes.filter { keptIndexes.contains($0.key) }
            sidecars = sidecars.filter { keptNotes.contains($0.key) }
        }
    }
}
