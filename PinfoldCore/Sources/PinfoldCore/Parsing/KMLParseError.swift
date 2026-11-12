import Foundation

public enum KMLParseError: Error, Equatable {
    /// XMLParser rejected the document. `line`/`column` come from `XMLParser.lineNumber`/
    /// `.columnNumber` at the point of failure; `detail` describes the underlying NSError by
    /// domain and code (not its localized message, which is locale-dependent).
    case malformedXML(line: Int, column: Int, detail: String)
    /// The document contains a DTD (`<!DOCTYPE …>`). KML never legitimately uses DTDs,
    /// so any document carrying one is rejected outright: XMLParser has no entity-expansion
    /// limit, and accepting DTDs would expose the parser to entity-expansion DoS payloads
    /// ("billion laughs").
    case dtdProhibited
    /// The root element is not a KML document root.
    case unsupportedRootElement(String)
    /// The bytes are in an encoding Pinfold cannot decode (e.g. malformed UTF-16/UTF-32).
    case unsupportedEncoding
}
