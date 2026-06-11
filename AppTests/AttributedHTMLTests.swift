import Foundation
@testable import Pinfold
import Testing

/// Tests for `AttributedHTML.plainText(_:)` and `AttributedHTML.readableText(_:)`.
///
/// KML `<description>` HTML is rendered as plain text only (the app never feeds untrusted
/// HTML to `NSAttributedString`'s `.html` importer), so these are pure string transforms —
/// no `@MainActor`, no UIKit.
struct AttributedHTMLTests {
    // MARK: - plainText (one-line previews)

    @Test func plainText_stripsSimpleTags() {
        #expect(AttributedHTML.plainText("<b>Hi</b>") == "Hi")
    }

    @Test func plainText_collapsesTagsAndWhitespaceToSingleLine() {
        let result = AttributedHTML.plainText("<b>Hi</b><br>there")
        #expect(result == "Hi there")
        #expect(!result.contains("<"))
    }

    @Test func plainText_noTags_isIdentity() {
        #expect(AttributedHTML.plainText("Just plain text") == "Just plain text")
    }

    @Test func plainText_emptyString_returnsEmpty() {
        #expect(AttributedHTML.plainText("") == "")
    }

    @Test func plainText_selfClosingTagIsStripped() {
        #expect(AttributedHTML.plainText("line1<br/>line2") == "line1 line2")
    }

    @Test func plainText_decodesEntities() {
        #expect(AttributedHTML.plainText("City &amp; Culture") == "City & Culture")
        #expect(AttributedHTML.plainText("Reykjavik&apos;s street") == "Reykjavik's street")
    }

    // MARK: - readableText (multi-line detail)

    @Test func readableText_brBecomesLineBreak() {
        #expect(AttributedHTML.readableText("Line one<br>Line two") == "Line one\nLine two")
    }

    @Test func readableText_doubleBrBecomesBlankLine() {
        #expect(AttributedHTML.readableText("Para one<br><br>Para two") == "Para one\n\nPara two")
    }

    @Test func readableText_paragraphsGetBlankLineBetween() {
        #expect(AttributedHTML.readableText("<p>First</p><p>Second</p>") == "First\n\nSecond")
    }

    @Test func readableText_bodyAndMetadataParagraphsBlankLineSeparated() {
        // Mirrors a Google-Earth style description: a body paragraph then metadata
        // paragraphs — each `<p>` block separated by a blank line.
        let html = "<p>Body sentence.</p><p><b>Day 1:</b> Arrive</p><p><b>Type:</b> Planned</p>"
        #expect(AttributedHTML.readableText(html) == "Body sentence.\n\nDay 1: Arrive\n\nType: Planned")
    }

    @Test func readableText_stripsInlineTagsKeepsText() {
        #expect(AttributedHTML.readableText("<p><b>Day 1:</b> Arrive</p>") == "Day 1: Arrive")
    }

    @Test func readableText_dropsAnchorTagKeepsLinkTextOnly() {
        // The href URL must be discarded (no network); only the visible text is kept.
        let result = AttributedHTML.readableText(
            "<a href=\"https://maps.google.com/?cid=123\">Open in Google Maps</a>"
        )
        #expect(result == "Open in Google Maps")
        #expect(!result.contains("http"))
    }

    @Test func readableText_trimsSourceIndentationPerLine() {
        let result = AttributedHTML.readableText("Title<br><br>         Indented body from CDATA")
        #expect(result == "Title\n\nIndented body from CDATA")
    }

    @Test func readableText_decodesNamedEntities() {
        #expect(AttributedHTML.readableText("City &amp; Culture") == "City & Culture")
        #expect(AttributedHTML.readableText("a &lt; b &gt; c") == "a < b > c")
    }

    @Test func readableText_decodesNumericEntities() {
        #expect(AttributedHTML.readableText("&#65;&#66;&#67;") == "ABC") // decimal
        #expect(AttributedHTML.readableText("&#x41;&#x42;") == "AB") // hex
    }

    @Test func readableText_ampDecodedLast_doubleEncodingPreserved() {
        // `&amp;lt;` is the literal text "&lt;" once decoded — NOT "<".
        #expect(AttributedHTML.readableText("&amp;lt;") == "&lt;")
    }

    @Test func readableText_emptyStringReturnsEmpty() {
        #expect(AttributedHTML.readableText("") == "")
    }

    // MARK: - attributed (tappable links)

    /// Returns every `URL` carried by a `.link` attribute, in run order.
    private func linkURLs(_ attributed: AttributedString) -> [URL] {
        attributed.runs.compactMap(\.link)
    }

    @Test func attributed_anchorBecomesTappableLink() throws {
        let result = AttributedHTML.attributed(
            "<a href=\"https://example.com/page\">See</a>"
        )
        #expect(String(result.characters) == "See")
        #expect(try linkURLs(result) == [#require(URL(string: "https://example.com/page"))])
        // The link covers exactly the visible anchor text.
        let linkedText = result.runs
            .filter { $0.link != nil }
            .map { String(result[$0.range].characters) }
            .joined()
        #expect(linkedText == "See")
    }

    @Test func attributed_javascriptHrefStripped() {
        let result = AttributedHTML.attributed(
            "<a href=\"javascript:alert(1)\">Click</a>"
        )
        #expect(String(result.characters) == "Click")
        #expect(linkURLs(result).isEmpty)
    }

    @Test func attributed_dataAndFileHrefStripped() {
        let dataResult = AttributedHTML.attributed("<a href=\"data:text/html,x\">D</a>")
        #expect(String(dataResult.characters) == "D")
        #expect(linkURLs(dataResult).isEmpty)

        let fileResult = AttributedHTML.attributed("<a href=\"file:///etc/passwd\">F</a>")
        #expect(String(fileResult.characters) == "F")
        #expect(linkURLs(fileResult).isEmpty)
    }

    @Test func attributed_mailtoAndTelAllowed() throws {
        let mailto = AttributedHTML.attributed("<a href=\"mailto:a@b.com\">Email</a>")
        #expect(String(mailto.characters) == "Email")
        #expect(try linkURLs(mailto) == [#require(URL(string: "mailto:a@b.com"))])

        let tel = AttributedHTML.attributed("<a href=\"tel:+15551234\">Call</a>")
        #expect(String(tel.characters) == "Call")
        #expect(try linkURLs(tel) == [#require(URL(string: "tel:+15551234"))])
    }

    @Test func attributed_bareURLDetected() throws {
        let result = AttributedHTML.attributed("Visit https://x.example/path now")
        #expect(String(result.characters) == "Visit https://x.example/path now")
        #expect(try linkURLs(result) == [#require(URL(string: "https://x.example/path"))])
    }

    @Test func attributed_bareEmailAndPhoneDetected() throws {
        let mail = AttributedHTML.attributed("Mail me@here.com today")
        #expect(try linkURLs(mail).contains(#require(URL(string: "mailto:me@here.com"))))

        let phone = AttributedHTML.attributed("Call +1 (800) 555-0199 now")
        // NSDataDetector produces a tel: URL for recognised phone numbers.
        #expect(linkURLs(phone).contains { $0.scheme == "tel" })
    }

    @Test func attributed_anchorTextNotDoubleLinked() throws {
        // The anchor's visible text is itself URL-shaped, but the href differs. The result
        // must carry exactly ONE link — the href — not a second detector link on the text.
        let result = AttributedHTML.attributed(
            "<a href=\"https://real.example/go\">https://shown.example</a>"
        )
        #expect(String(result.characters) == "https://shown.example")
        #expect(try linkURLs(result) == [#require(URL(string: "https://real.example/go"))])
    }

    @Test func attributed_nestedFormattingInsideAnchor() throws {
        let result = AttributedHTML.attributed(
            "<a href=\"https://example.com\"><b>bold link</b></a>"
        )
        #expect(String(result.characters) == "bold link")
        #expect(try linkURLs(result) == [#require(URL(string: "https://example.com"))])
    }

    @Test func attributed_pathologicalUnclosedAnchorsCompletesQuickly() {
        // ReDoS regression (untrusted input): pre-fix, the anchor pattern's lazy `(.*?)`
        // scanned to end-of-string for EVERY unclosed `<a` tag — O(n²), measured ~9 s for
        // this input. The bounded inner quantifier + input-length cap keep it ~linear; the
        // 2 s budget is generous so the test stays robust on slow CI simulators.
        let html = String(repeating: "<a href=\"https://x/\">", count: 3000)
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            _ = AttributedHTML.attributed(html)
        }
        #expect(elapsed < .seconds(2))
    }

    @Test func attributed_plainTextParityWhenNoLinks() {
        // For a fixture with no links, the attributed string's character content must equal
        // readableText's output — guards the shared-passes refactor.
        let html = "<p><b>Day 1:</b> Arrive</p><p>City &amp; Culture</p>"
        let result = AttributedHTML.attributed(html)
        #expect(String(result.characters) == AttributedHTML.readableText(html))
        #expect(linkURLs(result).isEmpty)
    }
}
