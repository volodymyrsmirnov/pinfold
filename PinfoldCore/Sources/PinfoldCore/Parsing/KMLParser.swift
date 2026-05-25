import Foundation

public enum KMLParseError: Error, Equatable {
    case malformedXML(String)
}

public enum KMLParser {
    public static func parse(data: Data) throws -> KMLDocument {
        let parser = XMLParser(data: data)
        let delegate = KMLParserDelegate()
        parser.delegate = delegate
        guard parser.parse() else {
            throw KMLParseError.malformedXML(parser.parserError?.localizedDescription ?? "unknown")
        }
        return delegate.makeDocument()
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
        init(id: String) { self.id = id }
        func build() -> KMLContainer {
            KMLContainer(id: id, name: name,
                         children: children.map { $0.build() },
                         placemarks: placemarks)
        }
    }

    private var idCounter = 0
    private func nextID(_ prefix: String) -> String { idCounter += 1; return "\(prefix)\(idCounter)" }

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
    }
    private var placemark: PlacemarkBuilder?

    // Set true while the parser is inside a <Point> element so that only Point
    // coordinates are captured, not LineString/Polygon vertices in the same placemark.
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
    private var styleMapCurrentKey: String?   // "normal" / "highlight"
    private var styleMapNormalURL: String?

    // ExtendedData assembly.
    private var inExtendedData = false
    private var currentDataName: String?
    private var currentDataValue: String?

    func makeDocument() -> KMLDocument {
        // Collapse a single top-level <Document>/<Folder> into the document's root.
        let effective: ContainerBuilder
        if rootBuilder.placemarks.isEmpty && rootBuilder.children.count == 1 {
            effective = rootBuilder.children[0]
        } else {
            effective = rootBuilder
        }
        return KMLDocument(name: effective.name, descriptionHTML: effective.description,
                           root: effective.build(), styles: styles, styleMaps: styleMaps)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        text = ""
        switch Self.localName(elementName) {
        case "Document", "Folder":
            let builder = ContainerBuilder(id: nextID("c"))
            containerStack.last?.children.append(builder)
            containerStack.append(builder)
        case "Placemark":
            placemark = PlacemarkBuilder()
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
            currentDataName = attributeDict["name"]
            currentDataValue = nil
        case "Point":
            placemark?.hasPoint = true
            inPoint = true
        case "LineString", "Polygon", "LinearRing", "MultiGeometry", "Model", "Track", "MultiTrack":
            if placemark != nil { placemark?.hasNonPointGeometry = true }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let s = String(data: CDATABlock, encoding: .utf8) { text += s }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
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
        case "description":
            // Captures description assuming CDATA-wrapped HTML (all Phase 1 fixtures use CDATA).
            // A raw non-CDATA <description> whose content includes child elements would be
            // truncated here because `text` resets on every didStartElement. Known Phase 1
            // limitation; revisit when rich-text / inline-HTML support is added.
            if placemark != nil {
                placemark?.descriptionHTML = text
            } else if let c = containerStack.last, c !== rootBuilder {
                c.description = text
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
            if inExtendedData { currentDataValue = text }
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
                                    value: value.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
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
                                             photoLinks: pm.photoLinks)
                    containerStack.last?.placemarks.append(built)
                }
            }
            placemark = nil
        default:
            break
        }
        text = ""
    }

    /// Returns the local name without a namespace prefix (e.g. "gx:Track" -> "Track").
    static func localName(_ raw: String) -> String {
        if let colon = raw.firstIndex(of: ":") { return String(raw[raw.index(after: colon)...]) }
        return raw
    }
}
