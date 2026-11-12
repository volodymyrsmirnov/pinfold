import Foundation

public enum KMLParser {
    public static func parse(data: Data) throws -> KMLDocument {
        // Normalise encoding/prolog first so the DOCTYPE scan below sees UTF-8 bytes even
        // for UTF-16/UTF-32 input — see `XMLPreflight`.
        let data = try XMLPreflight.normalize(data)
        // Reject DTDs with an internal subset (the only place entities can be declared) before
        // handing the bytes to XMLParser — see `dtdProhibited`.
        if prologHasProhibitedDoctype(data) {
            throw KMLParseError.dtdProhibited
        }
        return try parseUnguarded(data: data)
    }

    /// Runs `XMLParser` over already-normalised bytes without the prolog byte scan. The
    /// delegate's declaration callbacks are the second, encoding-independent DTD defence;
    /// this entry point exists so tests can exercise them in isolation.
    static func parseUnguarded(data: Data) throws -> KMLDocument {
        let parser = XMLParser(data: data)
        // External entity resolution must stay off. False is already XMLParser's default;
        // setting it explicitly documents the intent.
        parser.shouldResolveExternalEntities = false
        let delegate = KMLParserDelegate()
        parser.delegate = delegate
        let parsed = parser.parse()
        if let abortError = delegate.abortError {
            throw abortError
        }
        guard parsed else {
            let nsError = parser.parserError as NSError?
            let detail = nsError.map { "\($0.domain) code \($0.code)" } ?? "unknown"
            throw KMLParseError.malformedXML(line: parser.lineNumber,
                                             column: parser.columnNumber,
                                             detail: detail,
                                             code: nsError?.code ?? 0)
        }
        return delegate.makeDocument()
    }

    /// True if the document prolog holds a DOCTYPE that could declare entities: one with an
    /// internal subset (any `[` before the declaration's real closing `>`, inside or outside
    /// quoted literals) or one that never closes. A DOCTYPE with no subset carries no entity
    /// declarations and is allowed; `shouldResolveExternalEntities` stays false, so a SYSTEM
    /// or PUBLIC id is never fetched.
    ///
    /// The scan is bounded to the prolog: a DTD can only legally appear before the root
    /// element, so the scan walks the prolog constructs (XML declaration, processing
    /// instructions, comments, DOCTYPEs, whitespace) and stops at the first `<` that opens an
    /// element. This keeps the check O(prolog) instead of O(document) for legitimate
    /// multi-MB files, and means a literal "<!DOCTYPE" inside element content or CDATA is
    /// treated as plain text, not a DTD. The input is already UTF-8 (see `XMLPreflight`).
    private static func prologHasProhibitedDoctype(_ data: Data) -> Bool {
        let doctype = Array("<!DOCTYPE".utf8)
        let comment = Array("<!--".utf8)
        return data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Bool in
            let bytes = buffer.bindMemory(to: UInt8.self)

            /// Case-insensitive ASCII prefix match at `start`.
            func matches(_ needle: [UInt8], at start: Int) -> Bool {
                guard start + needle.count <= bytes.count else { return false }
                for offset in 0 ..< needle.count {
                    var byte = bytes[start + offset]
                    if byte >= 0x61, byte <= 0x7A {
                        byte -= 0x20
                    } // ASCII-uppercase letters
                    if byte != needle[offset] {
                        return false
                    }
                }
                return true
            }

            /// Index just past the declaration's closing `>`, or nil if it has a `[` or never closes.
            func endOfSubsetFreeDoctype(from start: Int) -> Int? {
                var quote: UInt8?
                var index = start
                while index < bytes.count {
                    let byte = bytes[index]
                    if byte == UInt8(ascii: "[") {
                        return nil
                    }
                    if let open = quote {
                        if byte == open {
                            quote = nil
                        }
                    } else if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") {
                        quote = byte
                    } else if byte == UInt8(ascii: ">") {
                        return index + 1
                    }
                    index += 1
                }
                return nil
            }

            var i = 0
            while i < bytes.count {
                guard bytes[i] == UInt8(ascii: "<") else {
                    i += 1 // whitespace or stray text before markup
                    continue
                }
                guard i + 1 < bytes.count else { return false }
                switch bytes[i + 1] {
                case UInt8(ascii: "?"):
                    // XML declaration / processing instruction: XML ends it at "?>", not at the
                    // first '>' (a PI may contain '>' and '<').
                    i += 2
                    while i + 1 < bytes.count, !(bytes[i] == UInt8(ascii: "?") && bytes[i + 1] == UInt8(ascii: ">")) {
                        i += 1
                    }
                    i += 2
                case UInt8(ascii: "!"):
                    if matches(doctype, at: i) {
                        guard let end = endOfSubsetFreeDoctype(from: i + doctype.count) else { return true }
                        i = end
                        continue
                    }
                    guard matches(comment, at: i) else {
                        // Some other "<!…" markup declaration in the prolog: not a DTD,
                        // and malformed XML that XMLParser will reject on its own.
                        return false
                    }
                    // Comment: skip past its closing "-->" (comments may contain '<').
                    let dash = UInt8(ascii: "-")
                    let gt = UInt8(ascii: ">")
                    i += comment.count
                    while i + 2 < bytes.count, !(bytes[i] == dash && bytes[i + 1] == dash && bytes[i + 2] == gt) {
                        i += 1
                    }
                    i += 3
                default:
                    // First element open tag: the prolog is over and a DTD can no longer
                    // legally appear.
                    return false
                }
            }
            return false
        }
    }
}
