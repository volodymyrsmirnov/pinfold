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
