import Foundation
import UIKit

/// Utilities for converting HTML strings to `AttributedString`.
///
/// HTML-to-`AttributedString` conversion via `NSAttributedString` is expensive and must
/// run on the main thread. Call `render(_:)` lazily — once, when a detail view appears —
/// rather than up-front or in a list. Never call it in bulk (e.g. inside a `List` body).
enum AttributedHTML {

    // MARK: - Main-actor render

    /// Converts an HTML string to an `AttributedString`.
    ///
    /// Uses `NSAttributedString(data:options:documentAttributes:)` with `.html` document
    /// type and UTF-8 encoding, then bridges the result to `AttributedString`. If the
    /// conversion fails for any reason (malformed HTML, unsupported encoding, etc.), falls
    /// back to `plainText(_:)` so the caller always receives readable text.
    ///
    /// The HTML importer applies its own default styling (a serif body font at ~12pt and a
    /// hard-coded black text color). To match the rest of the app, every run is remapped
    /// to the system **body** font — preserving bold/italic traits — and the importer's
    /// foreground color is stripped so the text adapts to light/dark mode. Links and other
    /// attributes are left intact.
    ///
    /// - Parameter html: An HTML string, e.g. a KML `<description>` value.
    /// - Returns: A styled `AttributedString`, or a plain-text fallback on failure.
    ///
    /// - Important: This method is `@MainActor`-bound. Call it from the main actor only.
    ///   Typically it should be called once inside a `.task` or `.onAppear` block and
    ///   stored in `@State`.
    @MainActor
    static func render(_ html: String) -> AttributedString {
        guard let data = html.data(using: .utf8),
              let nsAttr = try? NSAttributedString(
                  data: data,
                  options: [
                      .documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: NSUTF8StringEncoding
                  ],
                  documentAttributes: nil
              ) else {
            return AttributedString(plainText(html))
        }

        let normalized = normalizedForDisplay(nsAttr)
        guard let attributed = try? AttributedString(normalized, including: \.uiKit) else {
            return AttributedString(plainText(html))
        }
        return attributed
    }

    /// Spacing inserted after each paragraph (`<p>`), relative to the body font size.
    @MainActor
    private static var paragraphSpacing: CGFloat {
        UIFont.preferredFont(forTextStyle: .body).pointSize * 0.65
    }

    /// Normalizes the imported HTML for display: remaps fonts to the system body font
    /// (preserving bold/italic), drops the importer's fixed foreground color so the text
    /// adapts to light/dark, and adds spacing between paragraphs (existing paragraph
    /// attributes such as alignment are preserved).
    @MainActor
    private static func normalizedForDisplay(_ source: NSAttributedString) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: source)
        let bodyFont = UIFont.preferredFont(forTextStyle: .body)
        let fullRange = NSRange(location: 0, length: mutable.length)

        mutable.enumerateAttribute(.font, in: fullRange) { value, range, _ in
            // Preserve only the bold/italic traits from the imported font.
            let traits = (value as? UIFont)?.fontDescriptor.symbolicTraits ?? []
            var descriptor = bodyFont.fontDescriptor
            if let withTraits = descriptor.withSymbolicTraits(
                traits.intersection([.traitBold, .traitItalic])
            ) {
                descriptor = withTraits
            }
            let font = UIFont(descriptor: descriptor, size: bodyFont.pointSize)
            mutable.addAttribute(.font, value: font, range: range)
        }

        // Add space between paragraphs, preserving any existing paragraph style.
        let spacing = paragraphSpacing
        mutable.enumerateAttribute(.paragraphStyle, in: fullRange) { value, range, _ in
            let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
                ?? NSMutableParagraphStyle()
            style.paragraphSpacing = spacing
            mutable.addAttribute(.paragraphStyle, value: style, range: range)
        }

        // Drop the importer's hard-coded color so SwiftUI's default (adaptive) color wins.
        mutable.removeAttribute(.foregroundColor, range: fullRange)
        return mutable
    }

    // MARK: - Tag stripping fallback

    /// Returns a plain-text approximation of `html` by stripping all tags.
    ///
    /// This is the fallback used when `NSAttributedString` conversion fails. It performs
    /// a simple regex-based tag strip — it is not a full HTML parser and will not handle
    /// edge cases like `<` inside attribute values, but it is adequate as a best-effort
    /// fallback for KML description fields.
    ///
    /// - Parameter html: An HTML string.
    /// - Returns: The string with all `<tag>` occurrences removed.
    static func plainText(_ html: String) -> String {
        html.replacing(#/<[^>]*>/#, with: "")
    }
}
