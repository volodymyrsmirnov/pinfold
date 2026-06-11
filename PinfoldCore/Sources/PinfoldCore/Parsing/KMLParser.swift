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
        if containsDoctype(data) { throw KMLParseError.dtdProhibited }
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

    /// True if the data contains the ASCII bytes `<!DOCTYPE` (case-insensitive).
    private static func containsDoctype(_ data: Data) -> Bool {
        let needle: [UInt8] = Array("<!DOCTYPE".utf8) // uppercase ASCII
        guard data.count >= needle.count else { return false }
        return data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            let bytes = buffer.bindMemory(to: UInt8.self)
            for start in 0 ... (bytes.count - needle.count) {
                var matches = true
                for offset in 0 ..< needle.count {
                    var byte = bytes[start + offset]
                    if byte >= 0x61, byte <= 0x7A { byte -= 0x20 } // ASCII-uppercase letters
                    if byte != needle[offset] {
                        matches = false
                        break
                    }
                }
                if matches { return true }
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

    // StyleMap assembly.
    private var styleMapID: String?
    private var styleMapCurrentKey: String? // "normal" / "highlight"
    private var styleMapNormalURL: String?

    /// ExtendedData assembly.
    private var inExtendedData = false
    /// True while inside a <Data> element; <value> is only meaningful there.
    private var inDataElement = false
    private var currentDataName: String?
    private var currentDataValue: String?
    /// `name` attribute of the currently open <SimpleData> (SchemaData child).
    private var currentSimpleDataName: String?

    // Description capture. While > 0, every SAX event between <description> and its
    // matching </description> is re-serialized verbatim into `descriptionBuffer` so that
    // raw (non-CDATA) descriptions keep their inline HTML instead of being truncated by
    // the `text` reset on each child element. 0 = not capturing; 1 = directly inside
    // <description>; each nested child element adds 1.
    private var descriptionDepth = 0
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
    {
        if descriptionDepth > 0 {
            // Re-serialize the child element's open tag into the description verbatim;
            // do NOT reset `text` or otherwise touch normal element handling.
            descriptionBuffer += Self.serializedOpenTag(elementName, attributes: attributeDict)
            descriptionSawMarkup = true
            descriptionDepth += 1
            return
        }
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
            styleMapID = attributeDict["id"]
            styleMapNormalURL = nil
            styleMapCurrentKey = nil
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
    {
        if descriptionDepth > 0 {
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
            } else {
                // A child element inside the description closes: re-serialize it.
                descriptionBuffer += "</\(elementName)>"
            }
            return
        }
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
            }
            styleBuilder = nil
        case "key":
            styleMapCurrentKey = trimmed
        case "styleUrl":
            if placemark != nil {
                placemark?.styleUrl = trimmed
            } else if styleMapID != nil, styleMapCurrentKey == "normal" {
                styleMapNormalURL = trimmed
            }
        case "StyleMap":
            if let id = styleMapID, let normal = styleMapNormalURL {
                styleMaps[id] = normal
            }
            styleMapID = nil; styleMapCurrentKey = nil; styleMapNormalURL = nil
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
