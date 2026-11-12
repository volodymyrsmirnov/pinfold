import PinfoldCore

// MARK: - SearchCorpus

/// The folded searchable text of every placemark in one parsed document, built once (off the
/// main actor) so in-file search can match descriptions, extended-data values, snippets and
/// addresses without re-stripping HTML on every keystroke.
///
/// Keyed by the placemark's parse-order `id`, which is unique within one parse. Descriptions
/// are stripped of markup and capped (`PlacemarkIndex.descriptionCap`) before folding, so the
/// corpus matches exactly what the cross-file index matches.
struct SearchCorpus {
    private let folded: [String: String]

    /// Builds the corpus for every placemark under `root`.
    init(root: KMLContainer) {
        var folded: [String: String] = [:]
        for placemark in root.allPlacemarks {
            var parts: [String] = []
            if let name = placemark.name {
                parts.append(name)
            }
            if let text = PlacemarkIndex.searchableText(for: placemark) {
                parts.append(text)
            }
            folded[placemark.id] = SearchText.fold(parts.joined(separator: "\n"))
        }
        self.folded = folded
    }

    /// Whether the placemark `id`'s name or body contains the already-folded `foldedQuery`.
    func matches(placemarkID id: String, foldedQuery: String) -> Bool {
        guard let text = folded[id] else { return false }
        return SearchText.foldedContains(text, foldedQuery: foldedQuery)
    }

    /// The number of placemarks in the corpus (for tests).
    var count: Int {
        folded.count
    }
}
