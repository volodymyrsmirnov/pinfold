import Foundation

public enum KMLParseError: Error, Equatable {
    case malformedXML(String)
    /// The document contains a DTD (`<!DOCTYPE …>`). KML never legitimately uses DTDs,
    /// so any document carrying one is rejected outright: XMLParser has no entity-expansion
    /// limit, and accepting DTDs would expose the parser to entity-expansion DoS payloads
    /// ("billion laughs").
    case dtdProhibited
}

public enum KMLParser {
    public static func parse(data: Data) throws -> KMLDocument {
        // Reject DTDs before handing the bytes to XMLParser — see `dtdProhibited`.
        if prologContainsDoctype(data) { throw KMLParseError.dtdProhibited }
        let parser = XMLParser(data: data)
        // External entity resolution must stay off. False is already XMLParser's default;
        // setting it explicitly documents the intent.
        parser.shouldResolveExternalEntities = false
        let delegate = KMLParserDelegate()
        parser.delegate = delegate
        guard parser.parse() else {
            throw KMLParseError.malformedXML(parser.parserError?.localizedDescription ?? "unknown")
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
                    if byte >= 0x61, byte <= 0x7A { byte -= 0x20 } // ASCII-uppercase letters
                    if byte != needle[offset] { return false }
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
                    if matches(doctype, at: i) { return true }
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

/// SAX delegate that builds a KMLDocument. Containers (<Document>/<Folder>) are tracked
/// on a stack; placemarks are accumulated into the container on top of the stack.
final class KMLParserDelegate: NSObject, XMLParserDelegate {
    /// Mutable, reference-type container so parent/child builders share state on the stack.
    final class ContainerBuilder {
        let id: String
        var name: String?
        var description: String?
        var children: [ContainerBuilder] = []
        var placemarks: [KMLPlacemark] = []
        init(id: String) {
            self.id = id
        }

        func build() -> KMLContainer {
            KMLContainer(id: id, name: name,
                         children: children.map { $0.build() },
                         placemarks: placemarks)
        }
    }

    private var idCounter = 0
    private func nextID(_ prefix: String) -> String {
        idCounter += 1; return "\(prefix)\(idCounter)"
    }

    private let rootBuilder = ContainerBuilder(id: "root")
    private lazy var containerStack: [ContainerBuilder] = [rootBuilder]

    /// Current text accumulation for the open element.
    var text = ""

    /// Current placemark being assembled.
    struct PlacemarkBuilder {
        var name: String?
        var descriptionHTML: String?
        var styleUrl: String?
        var coordinate: Coordinate?
        var extendedData: [KMLDataItem] = []
        var photoLinks: [String] = []
        var hasPoint = false
        var geometries: [KMLGeometry] = []
        /// True if the placemark declared a non-point geometry we do NOT capture into
        /// `geometries` (e.g. `<Model>`, `<gx:MultiTrack>`). Such a placemark with no point
        /// and no captured geometry is dropped, preserving the pre-Task-7 behavior; a truly
        /// placeless placemark (description/data only, no geometry) stays kept.
        var hasUncapturedGeometry = false
        var sourceID: String?
    }

    var placemark: PlacemarkBuilder?

    /// Set true while the parser is inside a <Point> element so that only Point
    /// coordinates are captured, not LineString/Polygon vertices in the same placemark.
    var inPoint = false

    // Non-point geometry capture. Each context buffers vertices until its end element,
    // then flushes a KMLGeometry into the current placemark.
    var inLineString = false
    var lineStringCoords: [Coordinate] = []
    /// Polygon ring buffers. A Polygon collects one outer ring and zero or more inner rings;
    /// `inOuterBoundary`/`inInnerBoundary` route a LinearRing's coordinates to the right buffer.
    var inPolygon = false
    var inOuterBoundary = false
    var inInnerBoundary = false
    var polygonOuter: [Coordinate] = []
    var polygonInners: [[Coordinate]] = []
    var currentInnerRing: [Coordinate] = []
    /// gx:Track context. Each <gx:coord> appends one space-separated "lon lat [alt]" point.
    var inTrack = false
    var trackCoords: [Coordinate] = []

    // Style assembly.
    var styles: [String: KMLStyle] = [:]
    var styleMaps: [String: String] = [:]

    struct StyleBuilder {
        var id: String
        var iconHref: String?
        var iconColor: String?
        var iconScale: Double?
        var inIconStyle = false
        var lineColor: String?
        var lineWidth: Double?
        var polyColor: String?
        var polyFill: Bool?
        var inLineStyle = false
        var inPolyStyle = false
    }

    var styleBuilder: StyleBuilder?

    // StyleMap assembly. Each <Pair> buffers its <key> ("normal"/"highlight") and style
    // reference separately because KML allows them in either order; the pair is resolved
    // when it closes. The style reference comes from either a <styleUrl> child or an
    // inline <Style> child (indexed under a synthesized id).
    var styleMapID: String?
    var styleMapNormalURL: String?
    var inStyleMap = false
    var inPair = false
    var pairKey: String?
    var pairStyleURL: String?

    /// ExtendedData assembly.
    var inExtendedData = false
    /// True while inside a <Data> element; <value> is only meaningful there.
    var inDataElement = false
    var currentDataName: String?
    var currentDataValue: String?
    /// `name` attribute of the currently open <SimpleData> (SchemaData child).
    var currentSimpleDataName: String?

    /// Description capture. While > 0, every SAX event between <description> and its
    /// matching </description> is re-serialized verbatim into `descriptionBuffer` so that
    /// raw (non-CDATA) descriptions keep their inline HTML instead of being truncated by
    /// the `text` reset on each child element. 0 = not capturing; 1 = directly inside
    /// <description>; each nested child element adds 1.
    private var descriptionDepth = 0
    /// The captured buffer is display-HTML, not guaranteed well-formed XML (text content
    /// is entity-decoded verbatim, and void elements like <br> carry no closing tag).
    private var descriptionBuffer = ""
    /// True once a child element was re-serialized into the buffer. Used to decide
    /// whether to trim: markup-bearing descriptions are trimmed, while plain-text/CDATA
    /// descriptions pass through byte-identically to the pre-capture behavior.
    private var descriptionSawMarkup = false

    func makeDocument() -> KMLDocument {
        // Collapse a single top-level <Document>/<Folder> into the document's root.
        let effective: ContainerBuilder = if rootBuilder.placemarks.isEmpty, rootBuilder.children.count == 1 {
            rootBuilder.children[0]
        } else {
            rootBuilder
        }
        return KMLDocument(name: effective.name, descriptionHTML: effective.description,
                           root: effective.build(), styles: styles, styleMaps: styleMaps)
    }

    func parser(_: XMLParser, didStartElement elementName: String,
                namespaceURI _: String?, qualifiedName _: String?,
                attributes attributeDict: [String: String] = [:])
    // SwiftFormat owns brace placement and puts wrapped-signature braces on their own line.
    // swiftlint:disable:next opening_brace
    {
        if startElementWhileCapturingDescription(elementName, attributes: attributeDict) { return }
        text = ""
        let local = Self.localName(elementName)
        if startGeometryElement(local) { return }
        switch local {
        case "Document", "Folder":
            let builder = ContainerBuilder(id: nextID("c"))
            containerStack.last?.children.append(builder)
            containerStack.append(builder)
        case "Placemark":
            var builder = PlacemarkBuilder()
            builder.sourceID = attributeDict["id"]
            placemark = builder
        case "description":
            descriptionDepth = 1
            descriptionBuffer = ""
            descriptionSawMarkup = false
        case "Style":
            // Inline per-placemark styles (Style inside a Placemark) are intentionally not
            // captured in Phase 1 — only document-level styles are indexed. Phase 2 will
            // handle per-placemark rich styling.
            guard placemark == nil else { break }
            styleBuilder = StyleBuilder(id: attributeDict["id"] ?? nextID("s"))
        case "IconStyle":
            styleBuilder?.inIconStyle = true
        case "LineStyle":
            styleBuilder?.inLineStyle = true
        case "PolyStyle":
            styleBuilder?.inPolyStyle = true
        case "StyleMap":
            // Same Phase 1 scope restriction as Style — skip inline StyleMaps inside Placemarks.
            guard placemark == nil else { break }
            inStyleMap = true
            styleMapID = attributeDict["id"]
            styleMapNormalURL = nil
        case "Pair":
            guard inStyleMap else { break }
            inPair = true
            pairKey = nil
            pairStyleURL = nil
        case "ExtendedData":
            inExtendedData = true
        case "Data":
            inDataElement = true
            currentDataName = attributeDict["name"]
            currentDataValue = nil
        case "SimpleData":
            currentSimpleDataName = attributeDict["name"]
        default:
            break
        }
    }

    func parser(_: XMLParser, foundCharacters string: String) {
        if descriptionDepth > 0 { descriptionBuffer += string } else { text += string }
    }

    func parser(_: XMLParser, foundCDATA CDATABlock: Data) {
        guard let s = String(data: CDATABlock, encoding: .utf8) else { return }
        if descriptionDepth > 0 { descriptionBuffer += s } else { text += s }
    }

    func parser(_: XMLParser, didEndElement elementName: String,
                namespaceURI _: String?, qualifiedName _: String?)
    // SwiftFormat owns brace placement and puts wrapped-signature braces on their own line.
    // swiftlint:disable:next opening_brace
    {
        if endElementWhileCapturingDescription(elementName) { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let local = Self.localName(elementName)
        defer { text = "" }
        // Delegate cohesive element groups to helpers to keep this dispatcher's complexity low.
        guard !endGeometryElement(local),
              !endStyleElement(local, trimmed: trimmed),
              !endStyleMapElement(local, trimmed: trimmed),
              !endExtendedDataElement(local) else { return }
        switch local {
        case "Document", "Folder":
            containerStack.removeLast()
        case "name":
            if placemark != nil {
                placemark?.name = trimmed
            } else if let c = containerStack.last, c !== rootBuilder {
                c.name = trimmed
            }
        case "Placemark":
            if let pm = placemark { appendPlacemark(pm) }
            placemark = nil
        default:
            break
        }
    }

    /// Builds and appends a placemark, applying the keep-rule: keep if it has a Point OR any
    /// captured geometry. A point-less placemark's representative coordinate is the first
    /// coordinate of its first geometry.
    private func appendPlacemark(_ pm: PlacemarkBuilder) {
        // Keep a placemark with a point, with captured geometry, or with no geometry at all
        // (a description/data-only placeless placemark). Drop only a point-less placemark
        // whose sole geometry is an uncaptured non-point type.
        let keep = pm.hasPoint || !pm.geometries.isEmpty || !pm.hasUncapturedGeometry
        guard keep else { return }
        let coordinate = pm.hasPoint ? pm.coordinate : Self.firstCoordinate(of: pm.geometries)
        let built = KMLPlacemark(id: nextID("p"), name: pm.name,
                                 descriptionHTML: pm.descriptionHTML,
                                 styleUrl: pm.styleUrl,
                                 coordinate: coordinate,
                                 hasPoint: pm.hasPoint,
                                 geometries: pm.geometries,
                                 extendedData: pm.extendedData,
                                 photoLinks: pm.photoLinks,
                                 sourceID: pm.sourceID)
        containerStack.last?.placemarks.append(built)
    }

    /// First coordinate of the first geometry that has one — the representative point of a
    /// point-less geometry placemark.
    private static func firstCoordinate(of geometries: [KMLGeometry]) -> Coordinate? {
        for geometry in geometries {
            switch geometry {
            case let .lineString(coords), let .track(coords):
                if let first = coords.first { return first }
            case let .polygon(outer, _):
                if let first = outer.first { return first }
            }
        }
        return nil
    }

    // MARK: - Description capture

    /// Handles a start-element event while description capture is active.
    /// Returns true if the event was consumed (i.e. capture mode is on); the caller must
    /// then skip all normal element handling, including the `text` reset.
    private func startElementWhileCapturingDescription(
        _ elementName: String, attributes: [String: String]
    ) -> Bool {
        guard descriptionDepth > 0 else { return false }
        // Re-serialize the child element's open tag into the description verbatim.
        descriptionBuffer += Self.serializedOpenTag(elementName, attributes: attributes)
        descriptionSawMarkup = true
        descriptionDepth += 1
        return true
    }

    /// Handles an end-element event while description capture is active.
    /// Returns true if the event was consumed (i.e. capture mode is on).
    private func endElementWhileCapturingDescription(_ elementName: String) -> Bool {
        guard descriptionDepth > 0 else { return false }
        descriptionDepth -= 1
        if descriptionDepth == 0 {
            // </description> itself: assign the captured content. Markup-bearing
            // content is trimmed; plain-text/CDATA content is assigned untouched,
            // byte-identical to the pre-capture behavior.
            let html = descriptionSawMarkup
                ? descriptionBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                : descriptionBuffer
            if placemark != nil {
                placemark?.descriptionHTML = html
            } else if let c = containerStack.last, c !== rootBuilder {
                c.description = html
            }
            descriptionBuffer = ""
            descriptionSawMarkup = false
            text = ""
        } else if !Self.htmlVoidElements.contains(elementName.lowercased()) {
            // A child element inside the description closes: re-serialize it. HTML void
            // elements get no closing tag — XMLParser reports <br/> as start+end, but
            // "</br>" is invalid in the display-HTML this buffer holds.
            descriptionBuffer += "</\(elementName)>"
        }
        return true
    }

    /// HTML void elements that may appear in captured descriptions: re-serialized as a
    /// bare open tag (e.g. `<br>`), never with a closing tag.
    static let htmlVoidElements: Set<String> = ["br", "hr", "img", "wbr"]
}
