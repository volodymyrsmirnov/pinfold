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
/// A placemark row's `id` is the placemark's `stableKey` (durable across re-parses),
/// matching how the map keys selection and favorite/visited decoration.
///
/// ## Matching
/// Reuses the same primitive as `placemarksMatching(_:in:)` —
/// `localizedCaseInsensitiveContains` — so case/diacritic semantics stay identical.
/// A non-empty query keeps only matching placemarks and the ancestor folder rows that
/// lead to them; non-matching folders are omitted entirely. While a query is active the
/// `collapsed` set is ignored (force-expanded), so a match nested in a collapsed folder
/// is never hidden.
struct PlacemarkOutline {
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
        collapsed: Set<String>
    ) -> PlacemarkOutline {
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

            for placemark in container.placemarks where matches(placemark) {
                // `mappable` is independent of collapse/visibility: a collapsed folder
                // still plots on the map.
                if placemark.coordinate != nil { mappable.append(placemark) }
                if !hidden {
                    rows.append(Row(
                        kind: .placemark(placemark), depth: depth, id: placemark.stableKey
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
}
