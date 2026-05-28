import Foundation

/// Converts a KML `<description>` HTML string to plain text for display.
///
/// KML descriptions are **untrusted** — they come from arbitrary imported files — so the
/// app deliberately does **not** feed them to `NSAttributedString`'s `.html` importer. That
/// importer is WebKit-backed and issues synchronous network requests for any remote
/// subresources referenced in the markup (`<img>`, external CSS) while it parses: a
/// privacy/beaconing leak (it reveals that a file was opened, plus the device IP) and a
/// main-thread stall. These helpers instead strip tags locally — no HTML parsing, no
/// network — and decode the common HTML entities.
enum AttributedHTML {
    // MARK: - One-line plain text

    /// Tags stripped, entities decoded, every run of whitespace collapsed to a single
    /// space. Use for one-line previews (list rows, map preview card) shown with
    /// `lineLimit(1)`.
    static func plainText(_ html: String) -> String {
        let stripped = stripTags(html, lineBreak: " ", paragraphBreak: " ")
        return decodeEntities(stripped)
            .replacing(#/\s+/#, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Multi-line readable text

    /// `<br>` and block-level tags become line breaks, table cells become spaces, entities
    /// are decoded, and the source file's indentation plus runs of blank lines are removed
    /// so the result reads cleanly. Use for the placemark detail description.
    static func readableText(_ html: String) -> String {
        let decoded = decodeEntities(stripTags(html, lineBreak: "\n", paragraphBreak: "\n\n"))
        // KML CDATA descriptions frequently carry the source file's leading indentation;
        // trim each line and collapse consecutive blank lines.
        var lines: [String] = []
        for rawLine in decoded.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty, lines.last?.isEmpty == true { continue }
            lines.append(line)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Tag stripping

    /// Replaces `<br>` and per-item closes (`</li>`, `</tr>`) with `lineBreak`, block-level
    /// closes (`</p>`, `</div>`, headings, lists, …) with `paragraphBreak`, and table cells
    /// with a space, then removes every remaining tag. Using a doubled `paragraphBreak` for
    /// readable text puts a blank line between paragraphs so descriptions don't read cramped.
    private static func stripTags(_ html: String, lineBreak: String, paragraphBreak: String) -> String {
        var s = html
        s = s.replacing(#/(?i)<\s*br\s*/?>/#, with: lineBreak)
        s = s.replacing(#/(?i)<\s*/\s*(?:li|tr)\s*>/#, with: lineBreak)
        s = s.replacing(#/(?i)<\s*/\s*(?:p|div|blockquote|ul|ol|table|h[1-6])\s*>/#, with: paragraphBreak)
        s = s.replacing(#/(?i)<\s*/\s*(?:td|th)\s*>/#, with: " ")
        s = s.replacing(#/<[^>]*>/#, with: "")
        return s
    }

    // MARK: - Entity decoding

    /// Decodes the common named and numeric HTML entities. `&amp;` is decoded **last** so
    /// double-encoded input such as `&amp;lt;` becomes the literal `&lt;`, not `<`.
    private static func decodeEntities(_ html: String) -> String {
        var s = html
        // Numeric — hex (`&#xA0;`) first, then decimal (`&#160;`).
        s = s.replacing(#/&#x([0-9A-Fa-f]+);/#) { match in
            UInt32(match.1, radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                ?? String(match.0)
        }
        s = s.replacing(#/&#([0-9]+);/#) { match in
            UInt32(match.1, radix: 10).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                ?? String(match.0)
        }
        let named: [(String, String)] = [
            ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"),
        ]
        for (entity, replacement) in named {
            s = s.replacingOccurrences(of: entity, with: replacement)
        }
        return s.replacingOccurrences(of: "&amp;", with: "&")
    }
}
