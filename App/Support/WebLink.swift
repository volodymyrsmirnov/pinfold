import Foundation

/// Decides which text from a file becomes a tappable link (the Details chips). Values come from
/// untrusted files, so only a single plain http(s) address with a host qualifies — never
/// `javascript:`, `file:`, `mailto:`, or text that merely contains a URL.
enum WebLink {
    static func url(from value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host(), !host.isEmpty
        else { return nil }
        return url
    }
}
