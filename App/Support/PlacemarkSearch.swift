import PinfoldCore

// MARK: - PlacemarkSearch

/// Returns all placemarks in `document` matching `query`.
///
/// - When `query` is empty or all-whitespace, returns `document.root.allPlacemarks`
///   unchanged (the full flat list).
/// - Matching is case-, diacritic- and width-insensitive via `SearchText`.
/// - Without a `corpus`, only the name is matched (placemarks with a `nil` name are excluded).
///   With one, descriptions, extended-data values, snippets and addresses match too; `notes`
///   (placemark `stableKey` to note text) match as well.
///
/// This is a top-level function (not a method on any type) so it can be imported
/// and called from both views and tests without any coupling to SwiftUI.
///
/// - Parameters:
///   - query: The search string entered by the user.
///   - document: The parsed KML document to search.
///   - corpus: Optional prebuilt folded text for the document.
///   - notes: Optional personal notes keyed by `stableKey`.
/// - Returns: An array of matching `KMLPlacemark` values.
func placemarksMatching(
    _ query: String,
    in document: KMLDocument,
    corpus: SearchCorpus? = nil,
    notes: [String: String] = [:]
) -> [KMLPlacemark] {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    let all = document.root.allPlacemarks
    guard !trimmed.isEmpty else { return all }
    let matcher = PlacemarkOutline.Matcher(query: trimmed, corpus: corpus, notes: notes)
    return all.filter(matcher.matches)
}
