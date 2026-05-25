import PinfoldCore

// MARK: - PlacemarkSearch

/// Returns all placemarks in `document` whose `name` contains `query`.
///
/// - When `query` is empty or all-whitespace, returns `document.root.allPlacemarks`
///   unchanged (the full flat list).
/// - Matching is case-insensitive and locale-aware via `localizedCaseInsensitiveContains`.
/// - Placemarks with a `nil` name are excluded from non-empty query results.
///
/// This is a top-level function (not a method on any type) so it can be imported
/// and called from both views and tests without any coupling to SwiftUI.
///
/// - Parameters:
///   - query: The search string entered by the user.
///   - document: The parsed KML document to search.
/// - Returns: An array of matching `KMLPlacemark` values.
func placemarksMatching(_ query: String, in document: KMLDocument) -> [KMLPlacemark] {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    let all = document.root.allPlacemarks
    guard !trimmed.isEmpty else { return all }
    return all.filter { placemark in
        guard let name = placemark.name else { return false }
        return name.localizedCaseInsensitiveContains(trimmed)
    }
}

/// Returns a copy of `container` pruned to placemarks whose `name` matches `query`,
/// preserving the folder hierarchy so search results can be displayed grouped by
/// category just like the unfiltered view.
///
/// - When `query` is empty or all-whitespace, returns `container` unchanged.
/// - Matching is case-insensitive and locale-aware via `localizedCaseInsensitiveContains`;
///   placemarks with a `nil` name are excluded.
/// - Child folders are pruned recursively. A folder (or the whole container) that ends
///   up with no matching placemarks and no surviving children returns `nil`, so empty
///   folder headers never appear in the results.
///
/// - Parameters:
///   - container: The container (document root or folder) to filter.
///   - query: The search string entered by the user.
/// - Returns: A pruned `KMLContainer`, or `nil` if nothing in it matches.
func filteredContainer(_ container: KMLContainer, matching query: String) -> KMLContainer? {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return container }
    let matchedPlacemarks = container.placemarks.filter { placemark in
        guard let name = placemark.name else { return false }
        return name.localizedCaseInsensitiveContains(trimmed)
    }
    let prunedChildren = container.children.compactMap { filteredContainer($0, matching: trimmed) }
    guard !matchedPlacemarks.isEmpty || !prunedChildren.isEmpty else { return nil }
    return KMLContainer(
        id: container.id,
        name: container.name,
        children: prunedChildren,
        placemarks: matchedPlacemarks
    )
}
