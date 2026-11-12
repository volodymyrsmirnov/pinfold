import Foundation

/// One lexical unit of a KML description's HTML.
enum DescriptionToken: Equatable {
    /// Text with entities already decoded.
    case text(String)
    /// An opening (or self-closing) tag. `name` is lowercased; attribute names are lowercased
    /// and values entity-decoded.
    case open(name: String, attributes: [String: String])
    /// A closing tag; `name` is lowercased.
    case close(name: String)
}

/// A forgiving, single-pass tokenizer for untrusted description HTML.
///
/// Not an HTML parser: it never builds a tree, never loads anything and never allocates more
/// than a constant factor of the input. Every scan stops at the next `<`, so a crafted input
/// (thousands of unclosed tags, `<<<<`, giant attribute values) cannot make it superlinear.
/// Anything that does not look like a tag is kept as literal text, which is how unknown or
/// malformed markup "degrades to text".
enum DescriptionTokenizer {
    /// Longest span between `<` and `>` still treated as a tag; longer ones are literal text.
    private static let maxTagLength = 16 * 1024

    private static let lessThan = UInt8(ascii: "<")
    private static let greaterThan = UInt8(ascii: ">")
    private static let slash = UInt8(ascii: "/")
    private static let bang = UInt8(ascii: "!")
    private static let question = UInt8(ascii: "?")

    /// Tokenizes `html`, capped to `AttributedHTML.maxDescriptionLength` characters.
    static func tokens(_ html: String) -> [DescriptionToken] {
        let bytes = Array(String(html.prefix(AttributedHTML.maxDescriptionLength)).utf8)
        var tokens: [DescriptionToken] = []
        var textStart = 0
        var index = 0
        // Skipping `<script>`/`<style>` bodies: their text is never display content.
        var skipUntilClose: String?
        // A declaration with no terminator means none exists further on either; remembering that
        // keeps repeated unterminated `<!`/`<!--` from rescanning to the end each time.
        var exhausted = Set<Bool>()

        func flushText(upTo end: Int) {
            guard end > textStart else { return }
            let raw = string(bytes[textStart ..< end])
            tokens.append(.text(AttributedHTML.decodeEntities(raw)))
        }

        while index < bytes.count {
            guard bytes[index] == lessThan, let tag = scanTag(bytes, at: index, exhausted: &exhausted) else {
                index += 1
                continue
            }
            if skipUntilClose == nil {
                flushText(upTo: index)
            }
            textStart = tag.end
            index = tag.end
            switch tag.token {
            case .none:
                break
            case let .some(token):
                if let closing = skipUntilClose {
                    if token == .close(name: closing) {
                        skipUntilClose = nil
                    }
                    continue
                }
                if case let .open(name, _) = token, name == "script" || name == "style" {
                    skipUntilClose = name
                    continue
                }
                tokens.append(token)
            }
        }
        if skipUntilClose == nil {
            flushText(upTo: bytes.count)
        }
        return tokens
    }

    // MARK: - Tag scanning

    private struct ScannedTag {
        /// Index just past the closing `>`.
        let end: Int
        /// `nil` for markup that is consumed but produces nothing (comments, doctype).
        let token: DescriptionToken?
    }

    /// Scans the tag starting at `start` (a `<`), or returns `nil` when it is literal text.
    private static func scanTag(_ bytes: [UInt8], at start: Int, exhausted: inout Set<Bool>) -> ScannedTag? {
        let next = start + 1
        guard next < bytes.count else { return nil }
        let first = bytes[next]
        if first == bang || first == question {
            return scanDeclaration(bytes, at: start, exhausted: &exhausted)
        }
        let isClosing = first == slash
        let nameStart = isClosing ? next + 1 : next
        guard nameStart < bytes.count, isLetter(bytes[nameStart]) else { return nil }
        // Find the closing `>`; a `<` first, no `>`, or an over-long span means literal text.
        var end = nameStart
        let limit = min(bytes.count, start + maxTagLength)
        while end < limit, bytes[end] != greaterThan, bytes[end] != lessThan {
            end += 1
        }
        guard end < limit, bytes[end] == greaterThan else { return nil }
        let body = bytes[nameStart ..< end]
        let name = string(body.prefix(while: isNameByte)).lowercased()
        if isClosing {
            return ScannedTag(end: end + 1, token: .close(name: name))
        }
        let attributeBytes = body.dropFirst(name.utf8.count)
        return ScannedTag(end: end + 1, token: .open(name: name, attributes: parseAttributes(attributeBytes)))
    }

    /// Comments, doctype, CDATA and processing instructions: consumed, never displayed.
    private static func scanDeclaration(
        _ bytes: [UInt8], at start: Int, exhausted: inout Set<Bool>
    ) -> ScannedTag? {
        let isComment = bytes[start...].starts(with: Array("<!--".utf8))
        guard !exhausted.contains(isComment) else { return nil }
        let terminator: [UInt8] = isComment ? Array("-->".utf8) : [greaterThan]
        var index = start + 2
        while index + terminator.count <= bytes.count {
            if bytes[index] == terminator[0], bytes[index...].starts(with: terminator) {
                return ScannedTag(end: index + terminator.count, token: nil)
            }
            index += 1
        }
        exhausted.insert(isComment)
        // Unterminated: show it as text rather than swallowing the rest of the description.
        return nil
    }

    // MARK: - Attributes

    private static func parseAttributes(_ bytes: ArraySlice<UInt8>) -> [String: String] {
        var result: [String: String] = [:]
        var index = bytes.startIndex
        let end = bytes.endIndex
        while index < end {
            while index < end, isSpace(bytes[index]) || bytes[index] == slash {
                index += 1
            }
            let nameStart = index
            while index < end, !isSpace(bytes[index]), bytes[index] != UInt8(ascii: "="), bytes[index] != slash {
                index += 1
            }
            let name = string(bytes[nameStart ..< index]).lowercased()
            while index < end, isSpace(bytes[index]) {
                index += 1
            }
            guard index < end, bytes[index] == UInt8(ascii: "=") else {
                if !name.isEmpty {
                    result[name] = result[name] ?? ""
                }
                continue
            }
            index += 1
            while index < end, isSpace(bytes[index]) {
                index += 1
            }
            let value = readValue(bytes, from: &index)
            if !name.isEmpty, result[name] == nil {
                result[name] = AttributedHTML.decodeEntities(value)
            }
        }
        return result
    }

    private static func readValue(_ bytes: ArraySlice<UInt8>, from index: inout Int) -> String {
        let end = bytes.endIndex
        guard index < end else { return "" }
        let quote = bytes[index]
        if quote == UInt8(ascii: "\"") || quote == UInt8(ascii: "'") {
            index += 1
            let start = index
            while index < end, bytes[index] != quote {
                index += 1
            }
            let value = string(bytes[start ..< index])
            index = min(index + 1, end)
            return value
        }
        let start = index
        while index < end, !isSpace(bytes[index]) {
            index += 1
        }
        return string(bytes[start ..< index])
    }

    // MARK: - Byte classes

    /// Lossy UTF-8 decoding of a slice of the (already valid) input.
    private static func string(_ bytes: some Collection<UInt8>) -> String {
        // Slices of valid UTF-8, so the conversion is never lossy.
        // swiftlint:disable:next optional_data_string_conversion
        String(decoding: bytes, as: UTF8.self)
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
    }

    private static func isNameByte(_ byte: UInt8) -> Bool {
        isLetter(byte) || (byte >= 48 && byte <= 57) || byte == UInt8(ascii: ":") || byte == UInt8(ascii: "-")
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 32 || byte == 9 || byte == 10 || byte == 13 || byte == 12
    }
}
