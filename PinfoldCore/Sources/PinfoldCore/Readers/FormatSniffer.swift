import Foundation

/// Content-based format detection for plain (non-zip) input. Never trusts a file extension.
enum FormatSniffer {
    /// `.geoJSON` when the first non-whitespace byte (after an optional UTF-8 BOM) is `{` or
    /// `[`; otherwise the root element of the preflighted XML decides (`kml`/`Document`/
    /// `Folder`/`Placemark` -> KML, `gpx` -> GPX). Anything else is `unsupportedFormat`.
    static func sniff(_ data: Data) throws -> SourceFormat {
        guard let first = firstSignificantByte(data) else { throw KMLReadError.unsupportedFormat }
        if first == UInt8(ascii: "{") || first == UInt8(ascii: "[") {
            return .geoJSON
        }
        let normalized: Data
        do {
            normalized = try XMLPreflight.normalize(data)
        } catch KMLParseError.unsupportedEncoding where first >= 0x20 && first < 0x7F && first != UInt8(ascii: "<") {
            // Plain ASCII text that is not markup: not a map file at all.
            throw KMLReadError.unsupportedFormat
        }
        guard let root = rootElementName(normalized) else { throw KMLReadError.unsupportedFormat }
        if KMLParserDelegate.rootElements.contains(root) {
            return .kml
        }
        if root == "gpx" {
            return .gpx
        }
        throw KMLReadError.unsupportedFormat
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private static func firstSignificantByte(_ data: Data) -> UInt8? {
        var index = data.startIndex
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            index += 3
        }
        while index < data.endIndex, isSpace(data[index]) {
            index += 1
        }
        return index < data.endIndex ? data[index] : nil
    }

    /// Local name of the first element, skipping the prolog (declaration, PIs, comments, DOCTYPE).
    /// Bounded to the prolog, so it is O(prolog) on large documents.
    static func rootElementName(_ data: Data) -> String? {
        let bytes = Array(data.prefix(64 * 1024))
        var index = 0
        while index < bytes.count {
            guard bytes[index] == UInt8(ascii: "<"), index + 1 < bytes.count else {
                index += 1
                continue
            }
            switch bytes[index + 1] {
            case UInt8(ascii: "?"):
                index = end(of: Array("?>".utf8), in: bytes, from: index + 2)
            case UInt8(ascii: "!"):
                index = bytes[index...].starts(with: Array("<!--".utf8))
                    ? end(of: Array("-->".utf8), in: bytes, from: index + 4)
                    : endOfDoctype(bytes, from: index + 2)
            default:
                return elementName(bytes, from: index + 1)
            }
        }
        return nil
    }

    private static func end(of marker: [UInt8], in bytes: [UInt8], from start: Int) -> Int {
        var index = start
        while index + marker.count <= bytes.count {
            if bytes[index ..< index + marker.count].elementsEqual(marker) {
                return index + marker.count
            }
            index += 1
        }
        return bytes.count
    }

    private static func endOfDoctype(_ bytes: [UInt8], from start: Int) -> Int {
        var depth = 0
        var quote: UInt8?
        var index = start
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if let open = quote {
                if byte == open {
                    quote = nil
                }
            } else if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") {
                quote = byte
            } else if byte == UInt8(ascii: "[") {
                depth += 1
            } else if byte == UInt8(ascii: "]") {
                depth -= 1
            } else if byte == UInt8(ascii: ">"), depth <= 0 {
                return index
            }
        }
        return bytes.count
    }

    private static func elementName(_ bytes: [UInt8], from start: Int) -> String? {
        var index = start
        while index < bytes.count, !isSpace(bytes[index]), bytes[index] != UInt8(ascii: ">"),
              bytes[index] != UInt8(ascii: "/")
        {
            index += 1
        }
        let name = String(decoding: bytes[start ..< index], as: UTF8.self)
        guard !name.isEmpty else { return nil }
        return name.split(separator: ":").last.map(String.init)
    }
}
