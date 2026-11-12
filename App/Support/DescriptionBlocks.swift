import Foundation

/// A KML description's HTML reduced to a small set of displayable blocks, with no web view.
///
/// KML descriptions are untrusted, so this is a pure, linear tokenizer-driven reducer (see
/// `DescriptionTokenizer`): it recognises paragraphs, bold/italic/link runs, lists, tables
/// and images, and everything else degrades to its text. It never loads anything. Links keep
/// going through the `AttributedHTML.allowedURL` scheme allowlist (the security boundary),
/// and images are only *named* here; the view renders one only when its `src` is already in
/// the local resource cache.
enum DescriptionBlocks {
    // MARK: - Types

    /// A styled stretch of text inside a paragraph, list item or table cell.
    struct Run: Equatable {
        var text: String
        var isBold = false
        var isItalic = false
        /// An allowlisted destination, or `nil` for plain text.
        var link: URL?
    }

    enum Block: Equatable {
        case paragraph([Run])
        case list(ordered: Bool, items: [[Run]])
        /// Rows of cells (a Google My Maps style key/value table is rows of two cells).
        case table(rows: [[[Run]]])
        case image(src: String, alt: String?)
    }

    /// Upper bound on emitted blocks; the rest of an enormous description is dropped.
    static let maxBlocks = 500

    // MARK: - Entry points

    /// Reduces `html` (capped at 256 K characters) to blocks.
    static func parse(_ html: String) -> [Block] {
        var builder = DescriptionBlockBuilder()
        for token in DescriptionTokenizer.tokens(html) {
            builder.consume(token)
            if builder.blocks.count >= maxBlocks {
                break
            }
        }
        return builder.finish()
    }

    /// The image `src` values the description refers to that could be cached: `http(s)` URLs
    /// and relative references (KMZ-embedded), deduplicated, in document order. `data:`,
    /// `javascript:` and every other scheme are skipped.
    static func imageSources(in html: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for token in DescriptionTokenizer.tokens(html) {
            guard
                case let .open(name, attributes) = token, name == "img",
                let src = attributes["src"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                isCacheableSource(src), seen.insert(src).inserted
            else { continue }
            result.append(src)
        }
        return result
    }

    /// `true` for `http(s)` URLs and scheme-less (relative) references.
    static func isCacheableSource(_ src: String) -> Bool {
        guard !src.isEmpty else { return false }
        let lower = src.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return true
        }
        // A scheme is letters followed by ":" before any "/", "?" or "#"; relative otherwise.
        let head = lower.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        return !head.contains(":")
    }

    /// The plain text of `runs`, concatenated.
    static func text(of runs: [Run]) -> String {
        runs.map(\.text).joined()
    }
}

// MARK: - Attributed rendering

extension [DescriptionBlocks.Run] {
    /// The runs as an `AttributedString`: bold/italic through inline presentation intents,
    /// allowlisted anchors as links, and bare URLs / emails / phones detected in the rest.
    func attributed() -> AttributedString {
        var result = AttributedString()
        for run in self {
            var piece = AttributedString(run.text)
            var intent: InlinePresentationIntent = []
            if run.isBold {
                intent.insert(.stronglyEmphasized)
            }
            if run.isItalic {
                intent.insert(.emphasized)
            }
            if !intent.isEmpty {
                piece.inlinePresentationIntent = intent
            }
            piece.link = run.link
            result.append(piece)
        }
        return AttributedHTML.linkifyingBareURLs(result)
    }
}

// MARK: - Builder

/// The reducer behind `DescriptionBlocks.parse`: consumes tokens, tracks inline style, list
/// and table context, and emits blocks. Unknown tags are ignored (their text still flows).
struct DescriptionBlockBuilder {
    private(set) var blocks: [DescriptionBlocks.Block] = []

    private var runs: [DescriptionBlocks.Run] = []
    private var boldDepth = 0
    private var italicDepth = 0
    private var links: [URL?] = []

    private var listDepth = 0
    private var listOrdered = false
    private var listItems: [[DescriptionBlocks.Run]] = []

    private var tableDepth = 0
    private var rows: [[[DescriptionBlocks.Run]]] = []
    private var currentRow: [[DescriptionBlocks.Run]] = []
    private var inCell = false
    /// `true` while inside a `<th>`, whose text is bold.
    private var cellBold = false

    /// Images met inside a list or table; emitted after the container closes.
    private var pendingImages: [DescriptionBlocks.Block] = []

    private static let blockTags: Set<String> = [
        "p", "div", "blockquote", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "hr", "center",
    ]
    private static let headings: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6"]

    private var inStructure: Bool {
        listDepth > 0 || tableDepth > 0
    }

    // MARK: - Consuming

    mutating func consume(_ token: DescriptionToken) {
        switch token {
        case let .text(text):
            appendText(text)
        case let .open(name, attributes):
            open(name, attributes)
        case let .close(name):
            close(name)
        }
    }

    /// Flushes anything still open (unclosed tags degrade to the text they held).
    mutating func finish() -> [DescriptionBlocks.Block] {
        closeList()
        closeTable()
        flushParagraph()
        return blocks
    }

    // MARK: - Open / close

    private mutating func open(_ name: String, _ attributes: [String: String]) {
        switch name {
        case "br":
            appendText("\n")
        case "b", "strong":
            boldDepth += 1
        case "i", "em":
            italicDepth += 1
        case "a":
            links.append(attributes["href"].flatMap(AttributedHTML.allowedURL))
        case "img":
            emitImage(attributes)
        case "ul", "ol":
            openList(ordered: name == "ol")
        case "li":
            if listDepth > 0 {
                closeItem()
            }
        case "table":
            openTable()
        case "tr":
            if tableDepth > 0 {
                closeRow()
            }
        case "td", "th":
            openCell(bold: name == "th")
        default:
            if Self.blockTags.contains(name) {
                flushParagraph()
                if Self.headings.contains(name) {
                    boldDepth += 1
                }
            }
        }
    }

    private mutating func close(_ name: String) {
        switch name {
        case "b", "strong":
            boldDepth = max(0, boldDepth - 1)
        case "i", "em":
            italicDepth = max(0, italicDepth - 1)
        case "a":
            _ = links.popLast()
        case "ul", "ol":
            closeList()
        case "li":
            closeItem()
        case "table":
            closeTable()
        case "tr":
            closeRow()
        case "td", "th":
            closeCell()
            if name == "th" {
                boldDepth = max(0, boldDepth - 1)
            }
        default:
            if Self.blockTags.contains(name) {
                if Self.headings.contains(name) {
                    boldDepth = max(0, boldDepth - 1)
                }
                flushParagraph()
            }
        }
    }

    // MARK: - Text

    private mutating func appendText(_ raw: String) {
        // Inside a table but outside a cell, layout whitespace is dropped and anything else
        // opens an implicit cell, so stray text is never lost.
        if tableDepth > 0, !inCell {
            guard raw.contains(where: { !$0.isWhitespace }) else { return }
            inCell = true
        }
        let atLineStart = runs.last.map { $0.text.hasSuffix("\n") } ?? true
        let text = Self.tidy(raw, atLineStart: atLineStart)
        guard !text.isEmpty else { return }
        let link = links.last ?? nil
        let bold = boldDepth > 0 || cellBold
        let italic = italicDepth > 0
        if let last = runs.last, last.isBold == bold, last.isItalic == italic, last.link == link {
            runs[runs.count - 1].text += text
        } else {
            runs.append(.init(text: text, isBold: bold, isItalic: italic, link: link))
        }
    }

    /// Trims the indentation KML CDATA carries: spaces around every newline, leading space at
    /// the start of a line, and runs of blank lines collapsed to one.
    private static func tidy(_ raw: String, atLineStart: Bool) -> String {
        guard raw.contains(where: { $0 == "\n" || $0 == "\r" }) else {
            return atLineStart ? String(raw.drop { $0 == " " || $0 == "\t" }) : raw
        }
        let lines = raw.replacingOccurrences(of: "\r", with: "")
            .split(separator: "\n", omittingEmptySubsequences: false)
        var out: [String] = []
        for (position, line) in lines.enumerated() {
            var piece = Substring(line)
            if position > 0 || atLineStart {
                piece = piece.drop { $0 == " " || $0 == "\t" }
            }
            if position < lines.count - 1 {
                while piece.last == " " || piece.last == "\t" {
                    piece = piece.dropLast()
                }
            }
            out.append(String(piece))
        }
        var joined = out.joined(separator: "\n")
        while joined.contains("\n\n\n") {
            joined = joined.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return joined
    }

    // MARK: - Emitting

    /// Runs with leading and trailing whitespace trimmed and empty runs dropped.
    private static func trimmed(_ runs: [DescriptionBlocks.Run]) -> [DescriptionBlocks.Run] {
        var result = runs
        while let first = result.first {
            let text = String(first.text.drop { $0.isWhitespace })
            if text.isEmpty {
                result.removeFirst()
            } else {
                result[0].text = text
                break
            }
        }
        while let last = result.last {
            var text = last.text
            while text.last?.isWhitespace == true {
                text.removeLast()
            }
            if text.isEmpty {
                result.removeLast()
            } else {
                result[result.count - 1].text = text
                break
            }
        }
        return result
    }

    private mutating func flushParagraph() {
        guard !inStructure else { return }
        let content = Self.trimmed(runs)
        runs = []
        if !content.isEmpty {
            blocks.append(.paragraph(content))
        }
    }

    private mutating func emitImage(_ attributes: [String: String]) {
        guard let src = attributes["src"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              DescriptionBlocks.isCacheableSource(src)
        else { return }
        let alt = attributes["alt"].flatMap { $0.isEmpty ? nil : $0 }
        let block = DescriptionBlocks.Block.image(src: src, alt: alt)
        if inStructure {
            pendingImages.append(block)
        } else {
            flushParagraph()
            blocks.append(block)
        }
    }

    private mutating func flushPendingImages() {
        guard !inStructure else { return }
        blocks.append(contentsOf: pendingImages)
        pendingImages = []
    }

    // MARK: - Lists

    private mutating func openList(ordered: Bool) {
        if listDepth == 0 {
            flushParagraph()
            listOrdered = ordered
            listItems = []
        }
        listDepth += 1
    }

    private mutating func closeItem() {
        guard listDepth > 0 else { return }
        let item = Self.trimmed(runs)
        runs = []
        if !item.isEmpty {
            listItems.append(item)
        }
    }

    private mutating func closeList() {
        guard listDepth > 0 else { return }
        closeItem()
        listDepth -= 1
        guard listDepth == 0 else { return }
        if !listItems.isEmpty {
            blocks.append(.list(ordered: listOrdered, items: listItems))
        }
        listItems = []
        flushPendingImages()
    }

    // MARK: - Tables

    private mutating func openTable() {
        if tableDepth == 0 {
            flushParagraph()
            rows = []
            currentRow = []
            inCell = false
        }
        tableDepth += 1
    }

    private mutating func openCell(bold: Bool) {
        guard tableDepth > 0 else { return }
        closeCell()
        inCell = true
        cellBold = bold
    }

    private mutating func closeCell() {
        guard tableDepth > 0, inCell else { return }
        let cell = Self.trimmed(runs)
        runs = []
        inCell = false
        cellBold = false
        currentRow.append(cell)
    }

    private mutating func closeRow() {
        guard tableDepth > 0 else { return }
        closeCell()
        if currentRow.contains(where: { !$0.isEmpty }) {
            rows.append(currentRow)
        }
        currentRow = []
    }

    private mutating func closeTable() {
        guard tableDepth > 0 else { return }
        closeRow()
        tableDepth -= 1
        guard tableDepth == 0 else { return }
        if !rows.isEmpty {
            blocks.append(.table(rows: rows))
        }
        rows = []
        flushPendingImages()
    }
}
