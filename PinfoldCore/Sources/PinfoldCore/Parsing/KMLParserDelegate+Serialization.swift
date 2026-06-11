/// Stateless string helpers for the SAX delegate: namespace stripping and the open-tag
/// re-serialization used by description capture. Kept in a separate file to keep
/// `KMLParserDelegate`'s body focused on parse state.
extension KMLParserDelegate {
    /// Re-serializes an open tag (`<name attr="value" …>`) for description capture.
    /// Attributes are sorted by name for deterministic output.
    static func serializedOpenTag(_ name: String, attributes: [String: String]) -> String {
        var tag = "<\(name)"
        for (key, value) in attributes.sorted(by: { $0.key < $1.key }) {
            tag += " \(key)=\"\(escapedAttributeValue(value))\""
        }
        return tag + ">"
    }

    /// XML-escapes an attribute value (& < > ").
    static func escapedAttributeValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Returns the local name without a namespace prefix (e.g. "gx:Track" -> "Track").
    static func localName(_ raw: String) -> String {
        if let colon = raw.firstIndex(of: ":") { return String(raw[raw.index(after: colon)...]) }
        return raw
    }
}
