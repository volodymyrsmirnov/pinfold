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
///
/// `attributed(_:)` additionally turns `<a href>` anchors and bare URLs/emails/phone numbers
/// into tappable `.link` runs. Because the source is untrusted, the set of URL schemes that
/// may become a tappable action is an explicit **allowlist** (`http`, `https`, `mailto`,
/// `tel`) — `javascript:`, `data:`, `file:` and anything else render as plain, inert text.
/// This allowlist is the security boundary: a crafted description must never be able to hand
/// the user a one-tap `javascript:`/`file:` action.
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
        tidyLines(decodeEntities(stripTags(html, lineBreak: "\n", paragraphBreak: "\n\n")))
    }

    // MARK: - Attributed (tappable links)

    /// URL schemes that may become a tappable `.link`. Anything else (`javascript:`, `data:`,
    /// `file:`, …) is rendered as inert text. This allowlist is a **security boundary**:
    /// descriptions are untrusted, and a tappable link is a one-tap action, so we never expose
    /// schemes that could exfiltrate, run script, or read local files.
    private static let allowedLinkSchemes: Set<String> = ["http", "https", "mailto", "tel"]

    /// DoS bound for untrusted input: `attributed(_:)` only ever inspects this many characters
    /// of a description. 256 K characters is far beyond any legitimate KML description; the cap
    /// exists so a crafted multi-megabyte description can't tie up the anchor-extraction pass.
    /// `plainText`/`readableText` are NOT capped — their passes are all linear-time regexes, so
    /// the anchor pass here is the only superlinear-risk surface.
    private static let maxDescriptionLength = 256 * 1024

    /// Same tag-stripping / entity-decoding / line-tidying as `readableText`, but `<a href>`
    /// anchors with an allowlisted scheme, plus bare URLs / emails / phone numbers, become
    /// tappable `.link` runs. Pure string + `NSDataDetector` work — no HTML parsing, no
    /// network — so it is safe off the main thread. On link-free input the character content is
    /// byte-identical to `readableText` (it runs the same passes).
    static func attributed(_ html: String) -> AttributedString {
        // Cap the input first (see `maxDescriptionLength`): descriptions are untrusted and
        // unbounded. Truncating mid-anchor is harmless — the unmatched tag is just stripped.
        let html = String(html.prefix(maxDescriptionLength))

        // 1. Pull valid anchors out, replacing each with a private-use sentinel that survives
        //    the strip/decode/tidy passes, and remember each anchor's (visible text, URL).
        var anchors: [(text: String, url: URL)] = []
        // `<a … href="…">…</a>`: captures the href (group 1) and inner content (group 2).
        // Handles single- or double-quoted hrefs and attributes in any order; anchors don't
        // legally nest. The inner content match is **length-bounded** (`{0,1024}`, lazy): an
        // unbounded lazy `.*?` re-scans to end-of-string for every unclosed `<a` tag, which is
        // O(n²) on crafted input (measured ~9–11 s for 3000 unclosed anchors). With the bound,
        // each anchor candidate inspects at most 1024 characters, keeping the pass ~linear
        // (same input: ~0.3 s); anchors whose inner content exceeds the bound — far beyond any
        // real link text — simply degrade to plain text.
        let anchorPattern = #/(?is)<a\b[^>]*?\bhref\s*=\s*["']([^"']*)["'][^>]*>(.{0,1024}?)<\s*/\s*a\s*>/#
        let sentineled = html.replacing(anchorPattern) { match in
            let href = String(match.1)
            // Inner markup is stripped to text; entities decoded; whitespace collapsed.
            let text = plainText(String(match.2))
            guard
                !text.isEmpty,
                let url = allowedURL(href)
            else {
                // Disallowed scheme or empty text → keep just the visible text, no sentinel.
                return text
            }
            anchors.append((text, url))
            return "\(sentinelOpen)\(anchors.count - 1)\(sentinelClose)"
        }

        // 2. Run the shared readable-text pipeline over the sentineled string.
        let readable = readableText(String(sentineled))

        // 3. Reassemble, swapping each sentinel back for a linked run of its visible text.
        //
        // Forged sentinels: a description that literally embeds U+E000<idx>U+E001 with an
        // in-range idx binds attacker-chosen text to a REAL anchor's URL. That URL has already
        // cleared the scheme allowlist, so the impact is limited to link-text spoofing of an
        // allowlisted destination — no new scheme or action becomes reachable. Out-of-range or
        // malformed sentinels fail `nextSentinel` and degrade to inert text. Tracking anchor
        // ranges through the tidy passes instead (immune to forgery) was considered and
        // rejected as not worth the complexity for that residual impact.
        var result = AttributedString()
        var detectorRanges: [Range<AttributedString.Index>] = []
        var rest = Substring(readable)
        while let hit = nextSentinel(in: rest, anchorCount: anchors.count) {
            // Plain text before the sentinel is eligible for bare-URL/phone detection.
            let plain = AttributedString(String(rest[rest.startIndex ..< hit.open]))
            let plainStart = result.endIndex
            result.append(plain)
            detectorRanges.append(plainStart ..< result.endIndex)
            // The anchor itself: visible text carrying the href link (never re-detected).
            var link = AttributedString(anchors[hit.index].text)
            link.link = anchors[hit.index].url
            result.append(link)
            rest = rest[hit.close...]
        }
        let tailStart = result.endIndex
        result.append(AttributedString(String(rest)))
        detectorRanges.append(tailStart ..< result.endIndex)

        // 4. Detect bare URLs / emails / phone numbers in the non-anchor ranges only.
        detectLinks(in: &result, ranges: detectorRanges)
        return result
    }

    /// One located anchor sentinel: where its markers begin/end and which anchor it refers to.
    private struct SentinelHit {
        let open: Substring.Index
        let close: Substring.Index
        let index: Int
    }

    /// Locates the next valid anchor sentinel in `text` (only when its index is in range).
    private static func nextSentinel(in text: Substring, anchorCount: Int) -> SentinelHit? {
        guard
            let open = text.range(of: sentinelOpen),
            let close = text.range(of: sentinelClose, range: open.upperBound ..< text.endIndex),
            let index = Int(text[open.upperBound ..< close.lowerBound]),
            index >= 0, index < anchorCount
        else { return nil }
        return SentinelHit(open: open.lowerBound, close: close.upperBound, index: index)
    }

    private static let sentinelOpen = "\u{E000}"
    private static let sentinelClose = "\u{E001}"

    /// Returns a `URL` only when `href` parses and its scheme is in `allowedLinkSchemes`.
    private static func allowedURL(_ href: String) -> URL? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let url = URL(string: trimmed),
            let scheme = url.scheme?.lowercased(),
            allowedLinkSchemes.contains(scheme)
        else { return nil }
        return url
    }

    /// Runs `NSDataDetector(.link, .phoneNumber)` over each supplied range and applies a
    /// `.link` to bare URLs / emails (mailto:) / phone numbers (tel:). Phones come back as
    /// `tel:` URLs from the detector; links/emails already carry an allowed scheme.
    private static func detectLinks(
        in attributed: inout AttributedString,
        ranges: [Range<AttributedString.Index>]
    ) {
        guard let detector = sharedDetector else { return }
        for range in ranges where range.lowerBound < range.upperBound {
            let fragment = String(attributed[range].characters)
            let nsRange = NSRange(fragment.startIndex ..< fragment.endIndex, in: fragment)
            for match in detector.matches(in: fragment, range: nsRange) {
                let url = resolvedDetectorURL(match)
                guard
                    let url,
                    let swiftRange = Range(match.range, in: fragment),
                    let lower = AttributedString.Index(
                        swiftRange.lowerBound, within: attributed[range]
                    ),
                    let upper = AttributedString.Index(
                        swiftRange.upperBound, within: attributed[range]
                    )
                else { continue }
                attributed[lower ..< upper].link = url
            }
        }
    }

    /// Maps a detector match to an allowlisted `URL`. Phone numbers arrive as a string (not a
    /// URL), so we synthesise a `tel:` link from their digits; links and detector-built
    /// `mailto:` emails must clear `allowedURL`.
    private static func resolvedDetectorURL(_ match: NSTextCheckingResult) -> URL? {
        if match.resultType == .phoneNumber, let phone = match.phoneNumber {
            let digits = phone.filter { $0.isNumber || $0 == "+" }
            return URL(string: "tel:\(digits)")
        }
        if let detected = match.url {
            return allowedURL(detected.absoluteString)
        }
        return nil
    }

    private static let sharedDetector: NSDataDetector? = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
            | NSTextCheckingResult.CheckingType.phoneNumber.rawValue
    )

    /// KML CDATA descriptions frequently carry the source file's leading indentation; trim each
    /// line and collapse consecutive blank lines. Shared by the plain and attributed paths.
    private static func tidyLines(_ text: String) -> String {
        var lines: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
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
