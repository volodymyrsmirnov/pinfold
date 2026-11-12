import Foundation

/// Reads GPX 1.0/1.1 into the `KMLDocument` model. Same XML hardening as `KMLParser`:
/// encoding allow-list (`XMLPreflight`), prolog DOCTYPE guard, no external entities, and the
/// delegate aborts on any DTD declaration.
///
/// Mapping: each `wpt` is a point placemark; each `trk` is one placemark with a `.track` per
/// `trkseg`; each `rte` is one placemark with a `.lineString`. `metadata/name` is the document
/// name. When more than one kind is present the root holds "Waypoints", "Tracks" and "Routes"
/// folders (only the non-empty ones), otherwise the placemarks sit directly in the root.
enum GPXReader {
    static func read(_ data: Data) throws -> KMLDocument {
        try Task.checkCancellation()
        let data = try XMLPreflight.normalize(data)
        if KMLParser.prologHasProhibitedDoctype(data) {
            throw KMLParseError.dtdProhibited
        }
        return try parseUnguarded(data)
    }

    /// Runs `XMLParser` over already-normalised bytes without the prolog byte scan, so tests can
    /// exercise the delegate's declaration callbacks on their own.
    static func parseUnguarded(_ data: Data) throws -> KMLDocument {
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        let delegate = GPXParserDelegate()
        parser.delegate = delegate
        let parsed = parser.parse()
        if let abortError = delegate.abortError {
            throw abortError
        }
        guard parsed else {
            let nsError = parser.parserError as NSError?
            let detail = nsError.map { "\($0.domain) code \($0.code)" } ?? "unknown"
            throw KMLParseError.malformedXML(line: parser.lineNumber, column: parser.columnNumber,
                                             detail: detail, code: nsError?.code ?? 0)
        }
        return delegate.makeDocument()
    }
}
