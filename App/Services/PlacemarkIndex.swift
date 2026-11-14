import Foundation
import PinfoldCore

// MARK: - PlacemarkIndex

/// A per-entry, local-only search index (`placemarks-index.v2.json`) that backs
/// catalogue-wide placemark search ("which file has that campsite?").
///
/// The index is **derivable data**: it is a flattened list of every placemark's durable
/// `stableKey`, name, coordinate and searchable text, written into the entry's local
/// `resources/` cache directory alongside the icon/photo cache. Because it is fully
/// rebuildable from the original file, it never syncs — each device builds its own. It is
/// produced (a) at import commit from the already-parsed document and (b) by
/// `CatalogScanner.materializeMissingResources` for entries that synced in from another
/// device (or whose index predates v2). A missing or corrupt index is silently treated as
/// absent — the entry just doesn't contribute Places hits until the next pass rebuilds it.
///
/// All operations are pure / file-system only (no SwiftUI, no actor) so search can run
/// off the main actor. Decoded indexes are cached by `PlacemarkIndexStore`.
enum PlacemarkIndex {
    // MARK: - Filename

    /// The on-disk index filename inside an entry's `resources/` directory. The format version
    /// is part of the name, so "is the current index present?" is a plain `fileExists`.
    static let filename = "placemarks-index.v2.json"

    /// The v1 (names and coordinates only) index, still read as a fallback until the v2 file
    /// has been rebuilt for an entry.
    static let legacyFilename = "placemarks-index.json"

    /// Maximum characters of a description kept in `Entry.text`.
    static let descriptionCap = 1000

    // MARK: - Entry

    /// One indexed placemark: its durable identity, name, optional coordinate and searchable text.
    ///
    /// `key` is the placemark's `stableKey` (durable across re-parses), used to deep-link
    /// into the open file's outline. `name` is the empty string for a nameless placemark
    /// (kept rather than dropped so coordinate-only search/deep-links still resolve).
    /// `hasPoint` is true only for a real `<Point>` (D7). `text` is the unfolded searchable
    /// body (description plain text, extended-data values, snippet, address), or `nil`.
    struct Entry: Codable, Equatable {
        let key: String
        let name: String
        let lat: Double?
        let lon: Double?
        let hasPoint: Bool
        let text: String?

        init(key: String, name: String, lat: Double?, lon: Double?, hasPoint: Bool? = nil, text: String? = nil) {
            self.key = key
            self.name = name
            self.lat = lat
            self.lon = lon
            self.hasPoint = hasPoint ?? (lat != nil)
            self.text = text
        }

        // CodingKeys is the conventional nested type.
        // swiftlint:disable:next nesting
        private enum CodingKeys: String, CodingKey {
            case key, name, lat, lon, hasPoint, text
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(
                key: c.decode(String.self, forKey: .key),
                name: c.decode(String.self, forKey: .name),
                lat: c.decodeIfPresent(Double.self, forKey: .lat),
                lon: c.decodeIfPresent(Double.self, forKey: .lon),
                hasPoint: c.decodeIfPresent(Bool.self, forKey: .hasPoint),
                text: c.decodeIfPresent(String.self, forKey: .text)
            )
        }

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(key, forKey: .key)
            try c.encode(name, forKey: .name)
            try c.encodeIfPresent(lat, forKey: .lat)
            try c.encodeIfPresent(lon, forKey: .lon)
            try c.encode(hasPoint, forKey: .hasPoint)
            try c.encodeIfPresent(text, forKey: .text)
        }
    }

    // MARK: - Hit

    /// Where a search hit matched.
    enum MatchField: Equatable {
        case name
        /// Description, extended data, snippet or address.
        case description
        case note
    }

    /// One search hit: an `Entry` plus the entry folder it was found in, so the UI can
    /// group hits by file and deep-link into that file's detail.
    struct Hit: Identifiable {
        let folderName: String
        let key: String
        let name: String
        let lat: Double?
        let lon: Double?
        var hasPoint = true
        var matchedField: MatchField = .name
        /// A short excerpt around the match when it was not in the name.
        var snippet: String?

        /// Stable identity for `ForEach`: folder + placemark key are unique together.
        var id: String {
            "\(folderName)/\(key)"
        }
    }

    /// One searchable entry folder: its index directory and the sidecar holding notes/trash state.
    struct Source {
        let folderName: String
        let resourcesDir: URL
        /// The entry's `metadata.json`. `nil` means the sibling of `resourcesDir` (local layout).
        var sidecarURL: URL?

        var resolvedSidecarURL: URL {
            sidecarURL ?? resourcesDir.deletingLastPathComponent().appendingPathComponent("metadata.json")
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
                lon: placemark.coordinate?.longitude,
                hasPoint: placemark.hasPoint && placemark.coordinate != nil,
                text: searchableText(for: placemark)
            )
        }
    }

    /// The unfolded searchable body of a placemark besides its name: description plain text
    /// (capped), extended-data values, snippet, address and phone number. `nil` when there is none.
    static func searchableText(for placemark: KMLPlacemark) -> String? {
        var parts: [String] = []
        if let html = placemark.descriptionHTML, !html.isEmpty {
            let plain = AttributedHTML.plainText(String(html.prefix(50000)))
            if !plain.isEmpty {
                parts.append(String(plain.prefix(descriptionCap)))
            }
        }
        parts.append(contentsOf: placemark.extendedData.map(\.value).filter { !$0.isEmpty })
        if let snippet = placemark.snippet, !snippet.isEmpty {
            parts.append(snippet)
        }
        if let address = placemark.address, !address.isEmpty {
            parts.append(address)
        }
        if let phone = placemark.phoneNumber, !phone.isEmpty {
            parts.append(phone)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{2022} ")
    }

    // MARK: - Write

    /// Writes `entries` to `placemarks-index.v2.json` in `resourcesDir`, atomically.
    ///
    /// The list is sorted by `key` and the encoder uses `.sortedKeys` (mirroring
    /// `EntryMetadata.encoded()`) so the file is stable across rebuilds.
    static func write(_ entries: [Entry], to resourcesDir: URL) throws {
        let sorted = entries.sorted { $0.key < $1.key }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(sorted)
        try data.write(to: url(in: resourcesDir), options: .atomic)
    }

    // MARK: - Read

    /// Whether the current (v2) index exists in `resourcesDir`. A v1 file does not count, so
    /// the materialisation pass rebuilds it.
    static func exists(in resourcesDir: URL) -> Bool {
        FileManager.default.fileExists(atPath: url(in: resourcesDir).path)
    }

    /// Reads the index from `resourcesDir` (v2, else the v1 fallback), or `nil` when absent or
    /// undecodable. A `nil` result is non-fatal: the index is derivable and silently rebuildable.
    static func read(from resourcesDir: URL) -> [Entry]? {
        for name in [filename, legacyFilename] {
            let file = resourcesDir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: file) else { continue }
            if let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
                return decoded
            }
        }
        return nil
    }

    // MARK: - Search

    /// Convenience over `search(_:in:store:)` for callers without sidecar URLs (notes are read
    /// from the `metadata.json` beside each `resources/` folder).
    static func search(
        _ query: String,
        in dirs: [(folderName: String, resourcesDir: URL)],
        store: PlacemarkIndexStore = .shared
    ) -> [Hit] {
        let sources = dirs.map { Source(folderName: $0.folderName, resourcesDir: $0.resourcesDir) }
        return search(query, in: sources, store: store)
    }

    /// Returns every indexed placemark across `sources` whose name, searchable text or personal
    /// note matches `query` (case-, accent- and width-insensitive). An empty/whitespace query
    /// returns `[]`. Trashed entries, missing/corrupt indexes and tombstoned notes contribute
    /// nothing. Name matches win over note matches, which win over description matches.
    static func search(_ query: String, in sources: [Source], store: PlacemarkIndexStore = .shared) -> [Hit] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let folded = SearchText.fold(trimmed)
        var hits: [Hit] = []
        for source in sources {
            let notes = store.notes(at: source.resolvedSidecarURL)
            guard !notes.isTrashed, let snapshot = store.snapshot(for: source.resourcesDir) else { continue }
            for (index, entry) in snapshot.entries.enumerated() {
                guard let found = match(entry, at: index, in: snapshot, notes: notes, query: trimmed, folded: folded)
                else { continue }
                hits.append(Hit(
                    folderName: source.folderName, key: entry.key, name: entry.name,
                    lat: entry.lat, lon: entry.lon, hasPoint: entry.hasPoint,
                    matchedField: found.field, snippet: found.snippet
                ))
            }
        }
        return hits
    }

    // swiftlint:disable:next function_parameter_count
    private static func match(
        _ entry: Entry, at index: Int, in snapshot: PlacemarkIndexStore.Snapshot,
        notes: PlacemarkIndexStore.NotesSnapshot, query: String, folded: String
    ) -> (field: MatchField, snippet: String?)? {
        if SearchText.foldedContains(snapshot.foldedNames[index], foldedQuery: folded) {
            return (.name, nil)
        }
        if let note = notes.notes[entry.key], SearchText.foldedContains(note.folded, foldedQuery: folded) {
            return (.note, snippet(in: note.text, query: query))
        }
        if let text = entry.text, let body = snapshot.foldedTexts[index],
           SearchText.foldedContains(body, foldedQuery: folded)
        { // swiftlint:disable:this opening_brace
            return (.description, snippet(in: text, query: query))
        }
        return nil
    }

    /// A short excerpt of `text` around the first match of `query` (with ellipses when cut).
    static func snippet(in text: String, query: String, before: Int = 30, after: Int = 70) -> String {
        let flat = text.replacing(#/\s+/#, with: " ")
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        guard let range = flat.range(of: query, options: options, locale: .current) else {
            return String(flat.prefix(before + after))
        }
        let start = flat.index(range.lowerBound, offsetBy: -before, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(range.upperBound, offsetBy: after, limitedBy: flat.endIndex) ?? flat.endIndex
        let body = String(flat[start ..< end]).trimmingCharacters(in: .whitespaces)
        return (start > flat.startIndex ? "\u{2026}" : "") + body + (end < flat.endIndex ? "\u{2026}" : "")
    }

    // MARK: - Path

    private static func url(in resourcesDir: URL) -> URL {
        resourcesDir.appendingPathComponent(filename)
    }

    /// The v2 index file in `resourcesDir` (exposed for the marker helpers and tests).
    static func indexFile(in resourcesDir: URL) -> URL {
        url(in: resourcesDir)
    }
}
