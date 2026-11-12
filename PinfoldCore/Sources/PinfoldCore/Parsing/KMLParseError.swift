import Foundation

public enum KMLParseError: Error, Equatable {
    /// XMLParser rejected the document. `line`/`column` come from `XMLParser.lineNumber`/
    /// `.columnNumber` at the point of failure; `detail` describes the underlying NSError by
    /// domain and code (not its localized message, which is locale-dependent). `code` is the
    /// raw `XMLParser.ErrorCode` value, mapped to a readable reason by `errorDescription`.
    case malformedXML(line: Int, column: Int, detail: String, code: Int)
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

extension KMLParseError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .malformedXML(line, _, _, code):
            Self.malformedDescription(line: line, code: code)
        case .dtdProhibited:
            "This file declares entities in a DTD, which Pinfold does not open."
        case let .unsupportedRootElement(name):
            "This is not a KML file (it starts with <\(name)>)."
        case .unsupportedEncoding:
            "This file uses a text encoding Pinfold cannot read."
        }
    }

    private static func malformedDescription(line: Int, code: Int) -> String {
        let reason = reason(forXMLParserCode: code)
        guard line > 0 else { return reason.prefix(1).uppercased() + reason.dropFirst() }
        return "Line \(line): \(reason)"
    }

    /// Short lowercase reason for an `XMLParser.ErrorCode` raw value.
    private static func reason(forXMLParserCode code: Int) -> String {
        switch XMLParser.ErrorCode(rawValue: code) {
        case .emptyDocumentError: "the file is empty."
        case .prematureDocumentEndError: "the file ends unexpectedly."
        case .tagNameMismatchError, .gtRequiredError: "a tag is not closed."
        case .undeclaredEntityError, .entityRefAtEOFError, .entityRefInPrologError,
             .entityRefInEpilogError, .entityRefInDTDError: "it uses an undefined entity (such as &nbsp;)."
        case .invalidCharacterError, .invalidCharacterRefError, .invalidHexCharacterRefError,
             .invalidDecimalCharacterRefError: "it contains an invalid character."
        case .attributeNotStartedError, .attributeNotFinishedError, .equalExpectedError,
             .attributeRedefinedError, .literalNotStartedError, .literalNotFinishedError: "an attribute is malformed."
        case .lessThanSymbolInAttributeError: "an attribute contains a stray \"<\"."
        case .commentNotFinishedError: "a comment is not closed."
        case .xmlDeclNotFinishedError, .misplacedXMLDeclarationError: "the XML declaration is malformed."
        case .documentStartError: "the file does not start like an XML document."
        case .nameRequiredError, .pcdataRequiredError, .spaceRequiredError: "a tag is malformed."
        case .delegateAbortedParseError: "parsing was stopped."
        default: "the file is not valid XML."
        }
    }
}
