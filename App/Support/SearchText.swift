import Foundation

/// The single text-matching primitive behind file search, in-file search, cross-file search
/// and the Shortcuts picker, so every surface shares one definition of "matches".
enum SearchText {
    /// Whether `text` contains `query`, ignoring case in a locale-aware way (today's
    /// `localizedCaseInsensitiveContains` semantics).
    static func contains(_ text: String, query: String) -> Bool {
        text.localizedCaseInsensitiveContains(query)
    }
}
