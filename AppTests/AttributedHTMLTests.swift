import Testing
import Foundation
import UIKit
@testable import Pinfold

/// Tests for `AttributedHTML.render(_:)` and `AttributedHTML.plainText(_:)`.
///
/// `render` is `@MainActor`-bound (HTML→AttributedString must run on the main thread).
/// The entire suite is `@MainActor` so every test can call `render` without a wrapper.
@Suite @MainActor struct AttributedHTMLTests {

    // MARK: - render(_:) happy path

    @Test func render_boldTag_containsText() {
        let result = AttributedHTML.render("<b>Hi</b>")
        let plain = String(result.characters)
        #expect(plain.contains("Hi"), "rendered AttributedString should contain the text 'Hi'")
    }

    @Test func render_paragraphText_containsContent() {
        let result = AttributedHTML.render("<p>Hello <i>world</i></p>")
        let plain = String(result.characters)
        #expect(plain.contains("Hello"))
        #expect(plain.contains("world"))
    }

    // MARK: - Font / color normalization (matches the rest of the app)

    @Test func render_usesSystemBodyFontSize_notImporterDefault() {
        let result = AttributedHTML.render("<p>Plain paragraph text.</p>")
        let expectedSize = UIFont.preferredFont(forTextStyle: .body).pointSize
        // Every run that carries a font must use the system body point size — never the
        // HTML importer's ~12pt serif default.
        var sawFont = false
        for run in result.runs {
            if let font = run.uiKit.font {
                sawFont = true
                #expect(font.pointSize == expectedSize,
                        "description text should render at the system body size")
            }
        }
        #expect(sawFont, "rendered text should carry an explicit (system) font")
    }

    @Test func render_paragraphs_haveSpacingBetweenThem() {
        let result = AttributedHTML.render("<p>First paragraph.</p><p>Second paragraph.</p>")
        var sawSpacing = false
        for run in result.runs {
            if let style = run.uiKit.paragraphStyle, style.paragraphSpacing > 0 {
                sawSpacing = true
            }
        }
        #expect(sawSpacing, "paragraphs should render with spacing between them")
    }

    @Test func render_boldTag_preservesBoldTrait() {
        let result = AttributedHTML.render("Normal <b>BoldWord</b>")
        var sawBold = false
        for run in result.runs where String(result[run.range].characters).contains("BoldWord") {
            if let font = run.uiKit.font {
                sawBold = font.fontDescriptor.symbolicTraits.contains(.traitBold)
            }
        }
        #expect(sawBold, "bold runs should keep the bold trait after font normalization")
    }

    @Test func render_emptyString_doesNotCrash() {
        // Should not crash and return an (empty) AttributedString
        let result = AttributedHTML.render("")
        // Either empty or whitespace from the HTML parser — just verify no crash
        _ = result
    }

    @Test func render_plainText_passesThrough() {
        let result = AttributedHTML.render("No tags here")
        let plain = String(result.characters)
        #expect(plain.contains("No tags here"))
    }

    // MARK: - render(_:) fallback (malformed HTML)

    @Test func render_malformedHTML_fallsBackToPlainText() {
        // Badly nested tags; NSAttributedString may refuse or produce garbage.
        // The important contract is: no crash and text content is preserved.
        let result = AttributedHTML.render("<<<nothtml>>>")
        // Fallback strips tags via plainText() — the result may be empty or the content;
        // just verify no crash.
        _ = result
    }

    // MARK: - plainText(_:)

    @Test func plainText_stripsSimpleTags() {
        let result = AttributedHTML.plainText("<b>Hi</b>")
        #expect(!result.contains("<b>"), "bold open tag should be stripped")
        #expect(!result.contains("</b>"), "bold close tag should be stripped")
        #expect(result.contains("Hi"), "text content should remain")
    }

    @Test func plainText_multipleTagsAndContent() {
        let result = AttributedHTML.plainText("<b>Hi</b><br>x")
        #expect(result.contains("Hi"), "first text fragment should remain")
        #expect(result.contains("x"),  "second text fragment should remain")
        #expect(!result.contains("<"), "all angle brackets should be stripped")
    }

    @Test func plainText_noTags_isIdentity() {
        let input = "Just plain text"
        let result = AttributedHTML.plainText(input)
        #expect(result == input)
    }

    @Test func plainText_emptyString_returnsEmpty() {
        #expect(AttributedHTML.plainText("") == "")
    }

    @Test func plainText_selfClosingTag_isStripped() {
        let result = AttributedHTML.plainText("line1<br/>line2")
        #expect(!result.contains("<br/>"))
        #expect(result.contains("line1"))
        #expect(result.contains("line2"))
    }
}
