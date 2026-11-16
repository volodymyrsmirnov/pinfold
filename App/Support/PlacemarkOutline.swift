import CoreLocation
import CryptoKit
import Foundation
import PinfoldCore

// MARK: - PlacemarkOutline

/// A flattened, depth-tagged view of a `KMLContainer` tree, plus the matching
/// placemarks-with-coordinates list the map button needs — both computed in a single
/// walk so the view never re-traverses the tree separately.
///
/// Replaces the old recursive `AnyView`-wrapped sections in `KMLDetailView`: a flat
/// `[Row]` feeds one `List`, which lets SwiftUI lazily realize and diff rows instead of
/// eagerly building the whole `Section`/`DisclosureGroup` tree on every keystroke.
///
/// ## Folder identity
/// A folder's `id` is its **tree path of child indices**: the root is `""`, the root's
/// first child folder is `"0"`, that folder's second child folder is `"0/1"`, and so on.
/// This is stable across rebuilds as long as the parsed tree's shape is unchanged (it is —
/// the tree is re-parsed identically from the same file), which is what row identity and the
/// scroll anchor need. Folder rows for the root container itself are never emitted
/// (the root is implicit), so the smallest folder id is a single index like `"0"`.
///
/// The saved collapse state uses a different, durable key — `folderKey` (a hash of the folder's
/// name chain) — so it survives folders being added, removed or reordered around it.
///
/// A placemark row's `id` is its **document position** — the container's tree path plus the
/// placemark's index within that container (e.g. `"0/1/p2"`; root-level placemarks are `"p2"`).
/// The nearest-first sort, being flat, ids by document order (`"p<n>"`). This is unique *per
/// occurrence*, which `List`'s `ForEach` demands: a placemark's durable `stableKey` (what the map
/// and favorites key off) is NOT unique when the same POI repeats in a file — e.g. an itinerary
/// hotel listed on several days hashes to the same `name|lat|lon` — and duplicate `ForEach` ids
/// corrupt SwiftUI's diffing and scroll position ("undefined results").
///
/// ## Matching
/// Reuses the same primitive as `placemarksMatching(_:in:)` —
/// `localizedCaseInsensitiveContains` — so case/diacritic semantics stay identical.
/// A non-empty query keeps only matching placemarks and the ancestor folder rows that
/// lead to them; non-matching folders are omitted entirely. While a query is active the
/// `collapsed` set is ignored (force-expanded), so a match nested in a collapsed folder
/// is never hidden.
struct PlacemarkOutline {
    // MARK: - Folder keys

    /// The durable key of each child folder of `container`, for the saved collapse state:
    /// a hash of the parent's key, the folder's (trimmed) name and its occurrence among
    /// same-named siblings. Unlike the positional id it survives folders being added, removed
    /// or reordered around it; renaming a folder (or an ancestor) forgets its state. The root's
    /// key is `""`.
    static func childFolderKeys(of container: KMLContainer, parentKey: String) -> [String] {
        var occurrences: [String: Int] = [:]
        return container.children.map { child in
            let name = (child.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let occurrence = occurrences[name, default: 0]
            occurrences[name] = occurrence + 1
            return folderKey(parentKey: parentKey, name: name, occurrence: occurrence)
        }
    }

    private static func folderKey(parentKey: String, name: String, occurrence: Int) -> String {
        let digest = SHA256.hash(data: Data("\(parentKey)\u{1F}\(name)\u{1F}\(occurrence)".utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Sort

    /// How the outline orders its placemark rows.
    enum Sort: Equatable {
        /// Document order with the full folder hierarchy preserved (the default).
        case document
        /// A FLAT, distance-sorted list of placemark rows only — folder rows are dropped and
        /// the tree structure is ignored, since "nearest first" is inherently a global ordering
        /// that cuts across folders. Placemarks without a coordinate (no distance) sort last,
        /// keeping their relative document order. Requires the user's location; when it is
        /// absent the build falls back to `.document` (see `build`).
        case nearest(CLLocation)
    }

    // MARK: - Matcher

    /// Decides whether a placemark matches the trimmed `query`: by name always; and, when a
    /// `corpus` is supplied, by description / extended data / snippet / address; and by personal
    /// note text (`notes` keyed by `stableKey`). Without a corpus it is name-only, as before.
    struct Matcher {
        let query: String
        let corpus: SearchCorpus?
        let notes: [String: String]
        private let foldedQuery: String

        init(query: String, corpus: SearchCorpus?, notes: [String: String]) {
            self.query = query
            self.corpus = corpus
            self.notes = notes
            foldedQuery = SearchText.fold(query)
        }

        func matches(_ placemark: KMLPlacemark) -> Bool {
            guard !query.isEmpty else { return true }
            if let name = placemark.name, SearchText.contains(name, query: query) {
                return true
            }
            if corpus?.matches(placemarkID: placemark.id, foldedQuery: foldedQuery) == true {
                return true
            }
            if let note = notes[placemark.stableKey], !note.isEmpty {
                return SearchText.contains(note, query: query)
            }
            return false
        }
    }

    // MARK: - Row

    struct Row: Identifiable {
        // The row's kind discriminator. Naturally nested in Row.
        // swiftlint:disable:next nesting
        enum Kind {
            /// `id` is the positional tree path; `key` the durable collapse key (`folderKey`).
            case folder(name: String, id: String, key: String)
            case placemark(KMLPlacemark)
        }

        let kind: Kind
        let depth: Int
        let id: String

        var isFolder: Bool {
            if case .folder = kind {
                return true
            }
            return false
        }

        var isPlacemark: Bool {
            !isFolder
        }
    }

    let rows: [Row]
    /// The matched placemarks that have a coordinate, in document order — what the map
    /// button plots. Derived from the same walk as `rows`, ignoring collapse state (a
    /// collapsed folder still contributes its placemarks to the map).
    let mappablePlacemarks: [KMLPlacemark]

    // MARK: - Build

    static func build(
        from root: KMLContainer,
        matching query: String,
        collapsed: Set<String>,
        sort: Sort = .document,
        corpus: SearchCorpus? = nil,
        notes: [String: String] = [:]
    ) -> PlacemarkOutline {
        if case let .nearest(location) = sort {
            return buildNearest(from: root, matching: query, location: location, corpus: corpus, notes: notes)
        }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let isSearching = !trimmed.isEmpty
        // While searching, ignore the collapse state so matches in collapsed folders show.
        // The set holds durable folder keys (`childFolderKeys`), not positional ids.
        let effectiveCollapsed = isSearching ? Set<String>() : collapsed

        var rows: [Row] = []
        var mappable: [KMLPlacemark] = []

        let matcher = Matcher(query: trimmed, corpus: corpus, notes: notes)
        func matches(_ placemark: KMLPlacemark) -> Bool {
            matcher.matches(placemark)
        }

        /// Walks a container, appending rows for its matching placemarks and surviving
        /// child folders. `path` is the container's own tree path, `key` its durable folder key;
        /// `depth` its indent level. Returns true when this container contributed any visible
        /// row (a matching placemark or a surviving child) — used to prune empty folders while
        /// searching.
        @discardableResult
        func walk(_ container: KMLContainer, path: String, key: String, depth: Int, hidden: Bool) -> Bool {
            var contributed = false

            // Enumerate the FULL placemark list (not the filtered subset) so a row's id is its
            // position in the container and stays stable as a search query narrows the rows.
            for (index, placemark) in container.placemarks.enumerated() where matches(placemark) {
                // `mappable` is independent of collapse/visibility: a collapsed folder
                // still plots on the map.
                if placemark.coordinate != nil {
                    mappable.append(placemark)
                }
                if !hidden {
                    // Per-occurrence id (container path + placemark index), NOT `stableKey`: a
                    // repeated POI shares a stableKey, and duplicate ForEach ids corrupt scrolling.
                    let rowID = path.isEmpty ? "p\(index)" : "\(path)/p\(index)"
                    rows.append(Row(
                        kind: .placemark(placemark), depth: depth, id: rowID
                    ))
                }
                contributed = true
            }

            let childKeys = childFolderKeys(of: container, parentKey: key)
            for (index, child) in container.children.enumerated() {
                let childPath = path.isEmpty ? "\(index)" : "\(path)/\(index)"
                let childKey = childKeys[index]
                let childCollapsed = effectiveCollapsed.contains(childKey)
                // Build the child's rows into a temporary buffer so we can decide whether
                // to emit the folder header at all (prune empty folders when searching).
                let headerIndex = rows.count
                let folderHidden = hidden || childCollapsed
                if !hidden {
                    rows.append(Row(
                        kind: .folder(name: child.name ?? "Folder", id: childPath, key: childKey),
                        depth: depth, id: childPath
                    ))
                }
                let childContributed = walk(
                    child, path: childPath, key: childKey, depth: depth + 1, hidden: folderHidden
                )
                if childContributed {
                    contributed = true
                } else if !hidden, isSearching {
                    // Folder had no matches: drop its just-added header row.
                    rows.remove(at: headerIndex)
                }
            }

            return contributed
        }

        walk(root, path: "", key: "", depth: 0, hidden: false)
        return PlacemarkOutline(rows: rows, mappablePlacemarks: mappable)
    }

    // MARK: - Seen folders

    /// The durable keys (`childFolderKeys`) of folders whose places are ALL seen, counting
    /// places in their subfolders too. A folder with no places at all is never "all seen".
    static func fullySeenFolderKeys(in root: KMLContainer, visited: Set<String>) -> Set<String> {
        var result: Set<String> = []
        /// Returns (places in the subtree, of which seen).
        @discardableResult
        func walk(_ container: KMLContainer, key: String) -> (total: Int, seen: Int) {
            var total = container.placemarks.count
            var seen = container.placemarks.reduce(0) { $0 + (visited.contains($1.stableKey) ? 1 : 0) }
            for (child, childKey) in zip(container.children, childFolderKeys(of: container, parentKey: key)) {
                let counts = walk(child, key: childKey)
                total += counts.total
                seen += counts.seen
            }
            if !key.isEmpty, total > 0, seen == total {
                result.insert(key)
            }
            return (total, seen)
        }
        walk(root, key: "")
        return result
    }

    /// Folders that became all seen going from `oldVisited` to `newVisited` — the ones to
    /// collapse automatically. Only the transition counts, so a folder the user re-expands
    /// stays open until one of its places is unmarked and marked again.
    static func newlyFullySeenFolderKeys(
        in root: KMLContainer, from oldVisited: Set<String>, to newVisited: Set<String>
    ) -> Set<String> {
        guard !root.children.isEmpty, !newVisited.subtracting(oldVisited).isEmpty else { return [] }
        return fullySeenFolderKeys(in: root, visited: newVisited)
            .subtracting(fullySeenFolderKeys(in: root, visited: oldVisited))
    }

    /// Builds the flat, nearest-first outline: every matching placemark across the whole tree
    /// (folder structure ignored), sorted by distance from `location`. Each row sits at depth
    /// 0; no folder rows are emitted. Placemarks with a coordinate are ordered nearest→farthest;
    /// coordinate-less placemarks (no distance) follow, in document order. `mappablePlacemarks`
    /// keeps document order (the map plots them the same way regardless of this view sort).
    private static func buildNearest(
        from root: KMLContainer,
        matching query: String,
        location: CLLocation,
        corpus: SearchCorpus?,
        notes: [String: String]
    ) -> PlacemarkOutline {
        let matcher = Matcher(query: query.trimmingCharacters(in: .whitespaces), corpus: corpus, notes: notes)
        func matches(_ placemark: KMLPlacemark) -> Bool {
            matcher.matches(placemark)
        }

        // Flatten the whole tree into document-order placemarks (folders ignored).
        var flat: [KMLPlacemark] = []
        func collect(_ container: KMLContainer) {
            for placemark in container.placemarks where matches(placemark) {
                flat.append(placemark)
            }
            for child in container.children {
                collect(child)
            }
        }
        collect(root)

        /// Distance (nil for coordinate-less placemarks). A stable sort on the pre-indexed
        /// document order keeps equal/absent distances in their original relative order.
        func distance(_ placemark: KMLPlacemark) -> Double? {
            guard let coordinate = placemark.coordinate else { return nil }
            return location.distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
        }

        // Schwartzian transform: compute each distance once (allocating a CLLocation per
        // placemark) up front, rather than inside the comparator where it would run
        // O(N log N) times — costly for files with tens of thousands of placemarks.
        let decorated = flat.enumerated().map { offset, placemark in
            (offset: offset, placemark: placemark, distance: distance(placemark))
        }
        let sorted = decorated.sorted { lhs, rhs in
            switch (lhs.distance, rhs.distance) {
            case let (l?, r?): l != r ? l < r : lhs.offset < rhs.offset
            case (_?, nil): true // placed-on-map before coordinate-less
            case (nil, _?): false
            case (nil, nil): lhs.offset < rhs.offset
            }
        }

        // Id by flat document order (`offset`), NOT `stableKey`: a repeated POI shares a stableKey,
        // and duplicate ForEach ids corrupt scroll position. Folders are dropped here, so the
        // document-order index alone is unique.
        let rows = sorted.map { Row(kind: .placemark($0.placemark), depth: 0, id: "p\($0.offset)") }
        let mappable = flat.filter { $0.coordinate != nil }
        return PlacemarkOutline(rows: rows, mappablePlacemarks: mappable)
    }
}
