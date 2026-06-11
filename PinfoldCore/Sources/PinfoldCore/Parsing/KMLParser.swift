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
    private var text = ""

    /// Current placemark being assembled.
    private struct PlacemarkBuilder {
        var name: String?
        var descriptionHTML: String?
        var styleUrl: String?
        var coordinate: Coordinate?
        var extendedData: [KMLDataItem] = []
        var photoLinks: [String] = []
        var hasPoint = false
        var hasNonPointGeometry = false
        var sourceID: String?
    }

    private var placemark: PlacemarkBuilder?

    /// Set true while the parser is inside a <Point> element so that only Point
    /// coordinates are captured, not LineString/Polygon vertices in the same placemark.
    private var inPoint = false

    // Style assembly.
    private var styles: [String: KMLStyle] = [:]
    private var styleMaps: [String: String] = [:]

    private struct StyleBuilder {
        var id: String
        var iconHref: String?
        var iconColor: String?
        var iconScale: Double?
        var inIconStyle = false
    }

    private var styleBuilder: StyleBuilder?

    // StyleMap assembly. Each <Pair> buffers its <key> ("normal"/"highlight") and style
    // reference separately because KML allows them in either order; the pair is resolved
    // when it closes. The style reference comes from either a <styleUrl> child or an
    // inline <Style> child (indexed under a synthesized id).
    private var styleMapID: String?
    private var styleMapNormalURL: String?
    private var inStyleMap = false
    private var inPair = false
    private var pairKey: String?
    private var pairStyleURL: String?

    /// ExtendedData assembly.
    private var inExtendedData = false
    /// True while inside a <Data> element; <value> is only meaningful there.
    private var inDataElement = false
    private var currentDataName: String?
    private var currentDataValue: String?
    /// `name` attribute of the currently open <SimpleData> (SchemaData child).
    private var currentSimpleDataName: String?

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
        switch Self.localName(elementName) {
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
        case "Point":
            placemark?.hasPoint = true
            inPoint = true
        case "LineString", "Polygon", "LinearRing", "MultiGeometry", "Model", "Track", "MultiTrack":
            if placemark != nil { placemark?.hasNonPointGeometry = true }
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
        switch Self.localName(elementName) {
        case "Document", "Folder":
            containerStack.removeLast()
        case "name":
            if placemark != nil {
                placemark?.name = trimmed
            } else if let c = containerStack.last, c !== rootBuilder {
                c.name = trimmed
            }
        case "Point":
            inPoint = false
        case "coordinates":
            // Only capture coordinates while inside a <Point> so that LineString/Polygon
            // vertices in the same placemark don't clobber the Point coordinate.
            if placemark != nil, inPoint { placemark?.coordinate = Coordinate(parsingFirstTuple: text) }
        case "color":
            if styleBuilder?.inIconStyle == true { styleBuilder?.iconColor = trimmed }
        case "scale":
            if styleBuilder?.inIconStyle == true { styleBuilder?.iconScale = Double(trimmed) }
        case "href":
            if styleBuilder?.inIconStyle == true { styleBuilder?.iconHref = trimmed }
        case "IconStyle":
            styleBuilder?.inIconStyle = false
        case "Style":
            if let b = styleBuilder {
                styles[b.id] = KMLStyle(id: b.id, iconHref: b.iconHref,
                                        iconColor: b.iconColor, iconScale: b.iconScale)
                // An inline <Style> inside a StyleMap <Pair> acts as that pair's style
                // reference, equivalent to a <styleUrl> pointing at its (possibly
                // synthesized) id.
                if inPair { pairStyleURL = "#\(b.id)" }
            }
            styleBuilder = nil
        case "key":
            if inPair { pairKey = trimmed }
        case "styleUrl":
            if placemark != nil {
                placemark?.styleUrl = trimmed
            } else if inPair {
                pairStyleURL = trimmed
            }
        case "Pair":
            // Resolve only on close: KML allows <key> before or after the style reference.
            if pairKey == "normal", let url = pairStyleURL {
                styleMapNormalURL = url
            }
            inPair = false; pairKey = nil; pairStyleURL = nil
        case "StyleMap":
            if let id = styleMapID, let normal = styleMapNormalURL {
                styleMaps[id] = normal
            }
            inStyleMap = false
            styleMapID = nil; styleMapNormalURL = nil
        case "ExtendedData":
            inExtendedData = false
        case "value":
            // Only meaningful inside an open <Data>; a stray <value> elsewhere in
            // <ExtendedData> must not leak into the next data item.
            if inExtendedData, inDataElement { currentDataValue = text }
        case "SimpleData":
            if let name = currentSimpleDataName {
                placemark?.extendedData.append(KMLDataItem(name: name, value: trimmed))
            }
            currentSimpleDataName = nil
        case "Data":
            if let name = currentDataName {
                let value = currentDataValue ?? ""
                if name == "gx_media_links" {
                    let links = value
                        .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
                        .map(String.init)
                    placemark?.photoLinks.append(contentsOf: links)
                } else {
                    placemark?.extendedData.append(
                        KMLDataItem(name: name,
                                    value: value.trimmingCharacters(in: .whitespacesAndNewlines))
                    )
                }
            }
            inDataElement = false
            currentDataName = nil; currentDataValue = nil
        case "Placemark":
            if let pm = placemark {
                // Drop placemarks whose only geometry is non-point.
                let keep = pm.hasPoint || !pm.hasNonPointGeometry
                if keep {
                    let built = KMLPlacemark(id: nextID("p"), name: pm.name,
                                             descriptionHTML: pm.descriptionHTML,
                                             styleUrl: pm.styleUrl,
                                             coordinate: pm.hasPoint ? pm.coordinate : nil,
                                             extendedData: pm.extendedData,
                                             photoLinks: pm.photoLinks,
                                             sourceID: pm.sourceID)
                    containerStack.last?.placemarks.append(built)
                }
            }
            placemark = nil
        default:
            break
        }
        text = ""
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
    private static let htmlVoidElements: Set<String> = ["br", "hr", "img", "wbr"]

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
