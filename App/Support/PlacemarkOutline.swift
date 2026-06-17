import CoreLocation
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
/// the tree is re-parsed identically from the same file), which is exactly what is needed
/// to key the collapse state. Folder rows for the root container itself are never emitted
/// (the root is implicit), so the smallest folder id is a single index like `"0"`.
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

    // MARK: - Row

    struct Row: Identifiable {
        // The row's kind discriminator. Naturally nested in Row.
        // swiftlint:disable:next nesting
        enum Kind {
            case folder(name: String, id: String)
            case placemark(KMLPlacemark)
        }

        let kind: Kind
        let depth: Int
        let id: String

        var isFolder: Bool {
            if case .folder = kind { return true }
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
        sort: Sort = .document
    ) -> PlacemarkOutline {
        if case let .nearest(location) = sort {
            return buildNearest(from: root, matching: query, location: location)
        }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let isSearching = !trimmed.isEmpty
        // While searching, ignore the collapse state so matches in collapsed folders show.
        let effectiveCollapsed = isSearching ? Set<String>() : collapsed

        var rows: [Row] = []
        var mappable: [KMLPlacemark] = []

        func matches(_ placemark: KMLPlacemark) -> Bool {
            guard isSearching else { return true }
            guard let name = placemark.name else { return false }
            return name.localizedCaseInsensitiveContains(trimmed)
        }

        /// Walks a container, appending rows for its matching placemarks and surviving
        /// child folders. `path` is the container's own tree path; `depth` its indent level.
        /// Returns true when this container contributed any visible row (a matching
        /// placemark or a surviving child) — used to prune empty folders while searching.
        @discardableResult
        func walk(_ container: KMLContainer, path: String, depth: Int, hidden: Bool) -> Bool {
            var contributed = false

            // Enumerate the FULL placemark list (not the filtered subset) so a row's id is its
            // position in the container and stays stable as a search query narrows the rows.
            for (index, placemark) in container.placemarks.enumerated() where matches(placemark) {
                // `mappable` is independent of collapse/visibility: a collapsed folder
                // still plots on the map.
                if placemark.coordinate != nil { mappable.append(placemark) }
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

            for (index, child) in container.children.enumerated() {
                let childPath = path.isEmpty ? "\(index)" : "\(path)/\(index)"
                let childCollapsed = effectiveCollapsed.contains(childPath)
                // Build the child's rows into a temporary buffer so we can decide whether
                // to emit the folder header at all (prune empty folders when searching).
                let headerIndex = rows.count
                let folderHidden = hidden || childCollapsed
                if !hidden {
                    rows.append(Row(
                        kind: .folder(name: child.name ?? "Folder", id: childPath),
                        depth: depth, id: childPath
                    ))
                }
                let childContributed = walk(
                    child, path: childPath, depth: depth + 1, hidden: folderHidden
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

        walk(root, path: "", depth: 0, hidden: false)
        return PlacemarkOutline(rows: rows, mappablePlacemarks: mappable)
    }

    /// Builds the flat, nearest-first outline: every matching placemark across the whole tree
    /// (folder structure ignored), sorted by distance from `location`. Each row sits at depth
    /// 0; no folder rows are emitted. Placemarks with a coordinate are ordered nearest→farthest;
    /// coordinate-less placemarks (no distance) follow, in document order. `mappablePlacemarks`
    /// keeps document order (the map plots them the same way regardless of this view sort).
    private static func buildNearest(
        from root: KMLContainer,
        matching query: String,
        location: CLLocation
    ) -> PlacemarkOutline {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let isSearching = !trimmed.isEmpty

        func matches(_ placemark: KMLPlacemark) -> Bool {
            guard isSearching else { return true }
            guard let name = placemark.name else { return false }
            return name.localizedCaseInsensitiveContains(trimmed)
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
