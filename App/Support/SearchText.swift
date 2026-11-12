import Foundation

/// The single text-matching primitive behind file search, in-file search, cross-file search
/// and the Shortcuts picker, so every surface shares one definition of "matches": case-,
/// diacritic- and width-insensitive ("Reykjavik" finds "Reykjavík").
enum SearchText {
    private static let options: String.CompareOptions = [
        .caseInsensitive, .diacriticInsensitive, .widthInsensitive,
    ]

    /// Whether `text` contains `query`, ignoring case, diacritics and character width.
    static func contains(_ text: String, query: String) -> Bool {
        text.range(of: query, options: options, locale: .current) != nil
    }

    /// `text` reduced to its comparison form (case, diacritics and width removed), for text
    /// that is matched many times (search indexes, per-document corpora). Compare with
    /// `foldedContains(_:foldedQuery:)`.
    static func fold(_ text: String) -> String {
        text.folding(options: options, locale: .current)
    }

    /// Whether already-folded `foldedText` contains already-folded `foldedQuery`.
    static func foldedContains(_ foldedText: String, foldedQuery: String) -> Bool {
        foldedText.contains(foldedQuery)
    }
}
