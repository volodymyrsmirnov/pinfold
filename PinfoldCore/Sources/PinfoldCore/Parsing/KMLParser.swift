import Foundation

public enum KMLParser {
    public static func parse(data: Data) throws -> KMLDocument {
        // Reject DTDs before handing the bytes to XMLParser — see `dtdProhibited`.
        if prologContainsDoctype(data) {
            throw KMLParseError.dtdProhibited
        }
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
                                             detail: detail)
        }
        return delegate.makeDocument()
    }

    /// True if the document prolog contains the ASCII bytes `<!DOCTYPE` (case-insensitive).
    ///
    /// The scan is bounded to the prolog: a DTD can only legally appear before the root
    /// element, so the scan walks the prolog constructs (XML declaration, processing
    /// instructions, comments, whitespace/BOM) and stops at the first `<` that opens an
    /// element. This keeps the check O(prolog) instead of O(document) for legitimate
    /// multi-MB files, and means a literal "<!DOCTYPE" inside element content or CDATA is
    /// treated as plain text, not a DTD.
    private static func prologContainsDoctype(_ data: Data) -> Bool {
        let doctype: [UInt8] = Array("<!DOCTYPE".utf8) // uppercase ASCII
        let comment: [UInt8] = Array("<!--".utf8)
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

            var i = 0
            while i < bytes.count {
                guard bytes[i] == UInt8(ascii: "<") else {
                    i += 1 // whitespace, BOM bytes, or stray text before markup
                    continue
                }
                guard i + 1 < bytes.count else { return false }
                switch bytes[i + 1] {
                case UInt8(ascii: "?"):
                    // XML declaration / processing instruction: skip to its closing '>'.
                    while i < bytes.count, bytes[i] != UInt8(ascii: ">") {
                        i += 1
                    }
                    i += 1
                case UInt8(ascii: "!"):
                    if matches(doctype, at: i) {
                        return true
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
