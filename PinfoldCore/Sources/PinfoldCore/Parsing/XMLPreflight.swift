import Foundation

/// Input hygiene applied to raw bytes before the DOCTYPE guard and `XMLParser` see them.
///
/// Order matters: the encoding is normalised to UTF-8 **first**, so the ASCII-byte DOCTYPE
/// scan in `KMLParser` also sees UTF-16/UTF-32 documents (otherwise a wide-encoded DOCTYPE
/// would slip past it). Then the prolog is trimmed and XML-1.0-illegal control bytes are
/// removed. Input that needs no change is returned unchanged (no copy).
enum XMLPreflight {
    static func normalize(_ data: Data) throws -> Data {
        var data = try transcodeToUTF8(data)
        data = trimLeadingWhitespace(data)
        data = stripIllegalControlBytes(data)
        try requireSupportedEncoding(data)
        return data
    }

    // MARK: Encoding

    private enum WideEncoding {
        case utf16LE, utf16BE, utf32LE, utf32BE

        var stringEncoding: String.Encoding {
            switch self {
            case .utf16LE: .utf16LittleEndian
            case .utf16BE: .utf16BigEndian
            case .utf32LE: .utf32LittleEndian
            case .utf32BE: .utf32BigEndian
            }
        }
    }

    private static func transcodeToUTF8(_ data: Data) throws -> Data {
        let bytes = [UInt8](data.prefix(256))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            return data.dropFirst(3)
        }
        let detected = detectWide(bytes)
        guard let (encoding, bomLength) = detected else { return data }
        let payload = data.dropFirst(bomLength)
        guard var text = String(data: payload, encoding: encoding.stringEncoding) else {
            throw KMLParseError.unsupportedEncoding
        }
        if text.unicodeScalars.first == "\u{FEFF}" {
            text.unicodeScalars.removeFirst()
        }
        return Data(removeXMLDeclaration(text).utf8)
    }

    /// Detects UTF-32/UTF-16 by BOM, or BOM-less by the position of the first `<`.
    private static func detectWide(_ bytes: [UInt8]) -> (WideEncoding, Int)? {
        if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]) {
            return (.utf32LE, 4)
        }
        if bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            return (.utf32BE, 4)
        }
        if bytes.starts(with: [0xFF, 0xFE]) {
            return (.utf16LE, 2)
        }
        if bytes.starts(with: [0xFE, 0xFF]) {
            return (.utf16BE, 2)
        }
        // BOM-less: skip NULs and ASCII whitespace to the first `<`.
        var index = 0
        while index < bytes.count, [0x00, 0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
            index += 1
        }
        guard index < bytes.count, bytes[index] == 0x3C else { return nil }
        let zerosAfter = bytes[(index + 1)...].prefix(3).prefix { $0 == 0 }.count
        let zerosBefore = bytes[..<index].reversed().prefix(3).prefix { $0 == 0 }.count
        // Wide `<` is followed by NUL padding in both byte orders (`3C 00..` LE, `00 3C 00..` BE),
        // which keeps a stray leading NUL in a UTF-8 file from being mistaken for UTF-16BE.
        if zerosAfter == 3, index % 4 == 0 {
            return (.utf32LE, 0)
        }
        if zerosBefore == 3, zerosAfter == 3, index % 4 == 3 {
            return (.utf32BE, 0)
        }
        if zerosAfter >= 1, index % 2 == 0 {
            return (.utf16LE, 0)
        }
        if zerosBefore >= 1, zerosAfter >= 1, index % 2 == 1 {
            return (.utf16BE, 0)
        }
        return nil
    }

    /// Drops a leading `<?xml …?>` declaration: after transcoding its `encoding=` is stale.
    private static func removeXMLDeclaration(_ text: String) -> String {
        let trimmed = text.drop { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }
        guard trimmed.hasPrefix("<?xml"),
              let next = trimmed.dropFirst(5).first,
              next == " " || next == "\t" || next == "\n" || next == "\r" || next == "?",
              let close = trimmed.range(of: "?>") else { return text }
        return String(trimmed[close.upperBound...])
    }

    // MARK: Encoding allow-list

    /// Rejects input libxml2 could re-decode into something the byte-level DOCTYPE guard
    /// cannot see (UTF-7, EBCDIC, ...). Runs on the post-transcode, post-trim bytes: the first
    /// byte must be `<` (an EBCDIC `<` is 0x4C, a UTF-7 document still starts with `<?xml`), and
    /// any declared encoding must be on the allow-list.
    private static func requireSupportedEncoding(_ data: Data) throws {
        guard let first = data.first else { return } // empty: XMLParser reports it
        guard first == 0x3C else { throw KMLParseError.unsupportedEncoding }
        guard let name = declaredEncoding(in: data) else { return }
        guard isAllowedEncoding(name.lowercased()) else { throw KMLParseError.unsupportedEncoding }
    }

    /// The `encoding` pseudo-attribute of a leading `<?xml …?>` declaration, if any.
    private static func declaredEncoding(in data: Data) -> String? {
        let head = data.prefix(512)
        guard head.starts(with: Array("<?xml".utf8)), head.count > 5,
              [0x20, 0x09, 0x0A, 0x0D].contains(head[head.startIndex + 5]),
              let end = head.firstRange(of: Array("?>".utf8)) else { return nil }
        let declaration = String(bytes: head[..<end.lowerBound], encoding: .utf8) ?? ""
        guard let range = declaration.range(of: "encoding") else { return nil }
        var rest = declaration[range.upperBound...].drop { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }
        guard rest.first == "=" else { return nil }
        rest = rest.dropFirst().drop { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }
        guard let quote = rest.first, quote == "\"" || quote == "'" else { return nil }
        let value = rest.dropFirst()
        guard let close = value.firstIndex(of: quote) else { return nil }
        return String(value[..<close])
    }

    private static func isAllowedEncoding(_ name: String) -> Bool {
        let exact: Set = ["utf-8", "utf8", "us-ascii", "ascii", "latin1", "latin-1", "l1", "iso-ir-100",
                          "utf-16", "utf-32", "utf-16le", "utf-16be", "utf-32le", "utf-32be"]
        if exact.contains(name) {
            return true
        }
        for prefix in ["iso-8859-", "windows-125"] where name.hasPrefix(prefix) {
            let suffix = name.dropFirst(prefix.count)
            return !suffix.isEmpty && suffix.count <= 2 && suffix.allSatisfy(\.isNumber)
        }
        return false
    }

    // MARK: Prolog and control characters

    private static func trimLeadingWhitespace(_ data: Data) -> Data {
        var start = data.startIndex
        while start < data.endIndex, [0x20, 0x09, 0x0A, 0x0D].contains(data[start]) {
            start += 1
        }
        return start == data.startIndex ? data : data[start...]
    }

    /// Removes 0x00-0x08, 0x0B, 0x0C and 0x0E-0x1F (illegal in XML 1.0). Scans first and
    /// copies only when one is present.
    private static func stripIllegalControlBytes(_ data: Data) -> Data {
        func isIllegal(_ byte: UInt8) -> Bool {
            byte < 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D
        }
        guard data.contains(where: isIllegal) else { return data }
        return Data(data.filter { !isIllegal($0) })
    }
}
