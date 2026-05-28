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
}
