import Foundation
import PinfoldCore

// MARK: - PlacemarkIndex

/// A per-entry, local-only search index (`placemarks-index.json`) that backs
/// catalogue-wide placemark search ("which file has that campsite?").
///
/// The index is **derivable data**: it is a flattened list of every placemark's durable
/// `stableKey`, name, and coordinate, written into the entry's local `resources/` cache
/// directory alongside the icon/photo cache. Because it is fully rebuildable from the
/// original file, it never syncs — each device builds its own. It is produced (a) at
/// import commit from the already-parsed document and (b) by
/// `CatalogScanner.materializeMissingResources` for entries that synced in from another
/// device (that pass re-parses the original anyway). A missing or corrupt index is
/// silently treated as absent — the entry just doesn't contribute Places hits until the
/// next materialization pass rebuilds it.
///
/// All operations are pure / file-system only (no SwiftUI, no actor) so search can run
/// off the main actor.
enum PlacemarkIndex {
    // MARK: - Filename

    /// The on-disk index filename inside an entry's `resources/` directory.
    static let filename = "placemarks-index.json"

    // MARK: - Entry

    /// One indexed placemark: its durable identity, name, and optional coordinate.
    ///
    /// `key` is the placemark's `stableKey` (durable across re-parses), used to deep-link
    /// into the open file's outline. `name` is the empty string for a nameless placemark
    /// (kept rather than dropped so coordinate-only search/deep-links still resolve).
    struct Entry: Codable, Equatable {
        let key: String
        let name: String
        let lat: Double?
        let lon: Double?
    }

    // MARK: - Hit

    /// One search hit: an `Entry` plus the entry folder it was found in, so the UI can
    /// group hits by file and deep-link into that file's detail.
    struct Hit: Identifiable {
        let folderName: String
        let key: String
        let name: String
        let lat: Double?
        let lon: Double?

        /// Stable identity for `ForEach`: folder + placemark key are unique together.
        var id: String {
            "\(folderName)/\(key)"
        }
    }

    // MARK: - Build

    /// Builds index entries for every placemark in `document`, in document order.
    static func entries(for document: KMLDocument) -> [Entry] {
        document.root.allPlacemarks.map { placemark in
            Entry(
                key: placemark.stableKey,
                name: placemark.name ?? "",
                lat: placemark.coordinate?.latitude,
                lon: placemark.coordinate?.longitude
            )
        }
    }

    // MARK: - Write

    /// Writes `entries` to `placemarks-index.json` in `resourcesDir`, atomically.
    ///
    /// The list is sorted by `key` and the encoder uses `.sortedKeys` (mirroring
    /// `EntryMetadata.encoded()`) so the file is diff-friendly and stable across rebuilds.
    static func write(_ entries: [Entry], to resourcesDir: URL) throws {
        let sorted = entries.sorted { $0.key < $1.key }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(sorted)
        try data.write(to: url(in: resourcesDir), options: .atomic)
    }

    // MARK: - Read

    /// Reads the index from `resourcesDir`, or `nil` when the file is absent or cannot be
    /// decoded. A `nil` result is non-fatal: the index is derivable and silently
    /// rebuildable, so callers simply skip the entry until it is rematerialized.
    static func read(from resourcesDir: URL) -> [Entry]? {
        guard let data = try? Data(contentsOf: url(in: resourcesDir)),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data)
        else {
            return nil
        }
        return decoded
    }

    // MARK: - Search

    /// Returns every indexed placemark across `dirs` whose name matches `query`.
    ///
    /// Match semantics are identical to `placemarksMatching(_:in:)`: a trimmed, non-empty
    /// query matched case-insensitively and locale-aware via
    /// `localizedCaseInsensitiveContains`. An empty/whitespace query returns `[]` (the
    /// catalogue list, not a flood of every placemark). Directories whose index is missing
    /// or corrupt are silently skipped.
    static func search(_ query: String, in dirs: [(folderName: String, resourcesDir: URL)]) -> [Hit] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        var hits: [Hit] = []
        for dir in dirs {
            guard let entries = read(from: dir.resourcesDir) else { continue }
            for entry in entries where entry.name.localizedCaseInsensitiveContains(trimmed) {
                hits.append(Hit(
                    folderName: dir.folderName,
                    key: entry.key,
                    name: entry.name,
                    lat: entry.lat,
                    lon: entry.lon
                ))
            }
        }
        return hits
    }

    // MARK: - Path

    private static func url(in resourcesDir: URL) -> URL {
        resourcesDir.appendingPathComponent(filename)
    }
}
