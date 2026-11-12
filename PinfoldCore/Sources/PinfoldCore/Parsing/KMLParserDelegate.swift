import Foundation

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

        func build(styleUrlOverrides: [String: String] = [:]) -> KMLContainer {
            let built = styleUrlOverrides.isEmpty ? placemarks : placemarks.map { placemark in
                styleUrlOverrides[placemark.id].map { placemark.withStyleUrl($0) } ?? placemark
            }
            return KMLContainer(id: id, name: name,
                                children: children.map { $0.build(styleUrlOverrides: styleUrlOverrides) },
                                placemarks: built, descriptionHTML: description)
        }
    }

    /// Set by the delegate to abort parsing; `KMLParser.parse` rethrows it.
    var abortError: Error?

    /// Start elements seen, for the periodic cancellation check.
    private var startElementCount = 0
    private static let cancellationCheckInterval = 256

    private var idCounter = 0
    private func nextID(_ prefix: String) -> String {
        idCounter += 1; return "\(prefix)\(idCounter)"
    }

    private let rootBuilder = ContainerBuilder(id: "root")
    private lazy var containerStack: [ContainerBuilder] = [rootBuilder]

    /// Current text accumulation for the open element.
    var text = ""

    /// Local names of the currently open elements, outermost first. Pushed in
    /// `didStartElement` and popped in `didEndElement` on the normal path only (description
    /// capture runs its own depth counter and bypasses both). Lets `name`, `description` and
    /// `styleUrl` check their parent so stray elements (`atom:name`, overlay names, ...) are
    /// not mistaken for the document, folder or placemark ones.
    var elementStack: [String] = []

    /// Local names a KML document may start with (a full `<kml>` or a bare fragment).
    static let rootElements: Set<String> = ["kml", "Document", "Folder", "Placemark"]
    /// Parents under which `<name>` is meaningful.
    static let nameParents: Set<String> = ["Placemark", "Document", "Folder", "NetworkLink"]
    /// Parents under which `<description>` is stored; elsewhere it is swallowed and discarded.
    static let descriptionParents: Set<String> = ["Placemark", "Document", "Folder"]

    /// True only while inside an element whose character data is actually consumed on close
    /// (name, coordinates, gx:coord, style fields, key, styleUrl, value, SimpleData). When
    /// false, `foundCharacters`/`foundCDATA` skip accumulation entirely — most elements
    /// (containers, geometry wrappers, ExtendedData wrappers) carry text we never read, and
    /// appending it is wasted work on large documents. Description capture has its own buffer
    /// and is unaffected by this gate.
    var wantsText = false

    /// Element local names whose closing handler reads `text`/`trimmed`. Used to arm
    /// `wantsText` in `didStartElement`.
    static let textBearingElements: Set<String> = [
        "name", "coordinates", "coord", "color", "width", "fill", "scale", "href",
        "key", "styleUrl", "value", "SimpleData", "Snippet", "snippet", "address", "phoneNumber",
        "displayName",
    ]

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
        /// What 1.7 derived the placemark's `stableKey` and keep decision from.
        var legacy = LegacyKeyInputs()
        var sourceID: String?
        /// Coordinate donated by a dropped single-vertex line/track; locates a placemark that
        /// has no point and no kept geometry.
        var fallbackCoordinate: Coordinate?
        /// An inline `<Style>` (or the normal pair of an inline `<StyleMap>`).
        var inlineStyle: StyleFields?
        var snippet: String?
        var address: String?
        var phoneNumber: String?
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

    /// Network links collected in document order.
    var networkLinks: [KMLNetworkLink] = []
    /// Name and href of the open `<NetworkLink>`, flushed when it closes.
    var networkLinkName: String?
    var networkLinkHref: String?
    /// Inline styles collected from placemarks, merged and registered by `makeDocument()`.
    var pendingInlineStyles: [PendingInlineStyle] = []
    /// Inline `<Style>` buffered by the open `<Pair>` of an inline `<StyleMap>` in a placemark.
    var pairInlineStyle: StyleFields?

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
    var currentDataDisplayName: String?
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
    /// True when the open `<description>` sits under a parent whose description we do not
    /// keep (overlay, NetworkLink, ...): the content is still swallowed, then dropped.
    private var descriptionDiscard = false

    func makeDocument() -> KMLDocument {
        // Collapse a single top-level <Document>/<Folder> into the document's root.
        let effective: ContainerBuilder = if rootBuilder.placemarks.isEmpty, rootBuilder.children.count == 1 {
            rootBuilder.children[0]
        } else {
            rootBuilder
        }
        let overrides = resolveInlineStyles()
        return KMLDocument(name: effective.name, descriptionHTML: effective.description,
                           root: effective.build(styleUrlOverrides: overrides),
                           styles: styles, styleMaps: styleMaps, networkLinks: networkLinks)
    }

    // MARK: DTD declarations (defence in depth behind the byte-level DOCTYPE guard)

    private func rejectDeclaration(_ parser: XMLParser) {
        abortError = KMLParseError.dtdProhibited
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName _: String, value _: String?) {
        rejectDeclaration(parser)
    }

    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName _: String,
                publicID _: String?, systemID _: String?)
    // swiftlint:disable:next opening_brace
    {
        rejectDeclaration(parser)
    }

    func parser(_ parser: XMLParser, foundUnparsedEntityDeclarationWithName _: String, publicID _: String?,
                systemID _: String?, notationName _: String?)
    // swiftlint:disable:next opening_brace
    {
        rejectDeclaration(parser)
    }

    func parser(_ parser: XMLParser, foundElementDeclarationWithName _: String, model _: String) {
        rejectDeclaration(parser)
    }

    func parser(_ parser: XMLParser, foundAttributeDeclarationWithName _: String, forElement _: String,
                type _: String?, defaultValue _: String?)
    // swiftlint:disable:next opening_brace
    {
        rejectDeclaration(parser)
    }

    func parser(_ parser: XMLParser, foundNotationDeclarationWithName _: String,
                publicID _: String?, systemID _: String?)
    // swiftlint:disable:next opening_brace
    {
        rejectDeclaration(parser)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI _: String?, qualifiedName _: String?,
                attributes attributeDict: [String: String] = [:])
    // SwiftFormat owns brace placement and puts wrapped-signature braces on their own line.
    // swiftlint:disable:next opening_brace
    {
        startElementCount += 1
        if startElementCount % Self.cancellationCheckInterval == 0, Task.isCancelled {
            abortError = CancellationError()
            parser.abortParsing()
            return
        }
        if startElementWhileCapturingDescription(elementName, attributes: attributeDict) {
            return
        }
        text = ""
        let local = Self.localName(elementName)
        let parent = elementStack.last
        if parent == nil, !Self.rootElements.contains(local) {
            abortError = KMLParseError.unsupportedRootElement(local)
            parser.abortParsing()
            return
        }
        elementStack.append(local)
        // Arm text accumulation only for elements whose close actually reads it.
        wantsText = Self.textBearingElements.contains(local)
        if startGeometryElement(local) {
            return
        }
        switch local {
        case "Document", "Folder":
            let builder = ContainerBuilder(id: nextID("c"))
            containerStack.last?.children.append(builder)
            containerStack.append(builder)
        case "NetworkLink":
            networkLinkName = nil
            networkLinkHref = nil
        case "Placemark":
            var builder = PlacemarkBuilder()
            builder.sourceID = attributeDict["id"]
            placemark = builder
        case "description":
            descriptionDepth = 1
            descriptionBuffer = ""
            descriptionSawMarkup = false
            descriptionDiscard = !(parent.map(Self.descriptionParents.contains) ?? false)
        case "Style":
            // Inside a Placemark the style is inline: `closeStyleElement` hands it to the
            // placemark rather than indexing it by id.
            // An inline style gets a throwaway id: it must not consume the shared counter,
            // or every later `p:pN` key would shift relative to 1.7.
            styleBuilder = StyleBuilder(id: attributeDict["id"] ?? (placemark == nil ? nextID("s") : "inline"))
        case "IconStyle":
            styleBuilder?.inIconStyle = true
        case "LineStyle":
            styleBuilder?.inLineStyle = true
        case "PolyStyle":
            styleBuilder?.inPolyStyle = true
        case "StyleMap":
            inStyleMap = true
            styleMapID = placemark == nil ? attributeDict["id"] : nil
            styleMapNormalURL = nil
        case "Pair":
            guard inStyleMap else { break }
            inPair = true
            pairKey = nil
            pairStyleURL = nil
            pairInlineStyle = nil
        case "ExtendedData":
            inExtendedData = true
        case "Data":
            inDataElement = true
            currentDataName = attributeDict["name"]
            currentDataValue = nil
            currentDataDisplayName = nil
        case "SimpleData":
            currentSimpleDataName = attributeDict["name"]
        default:
            break
        }
    }

    func parser(_: XMLParser, foundCharacters string: String) {
        if descriptionDepth > 0 {
            descriptionBuffer += string
        } else if wantsText {
            text += string
        }
    }

    func parser(_: XMLParser, foundCDATA CDATABlock: Data) {
        guard let s = String(data: CDATABlock, encoding: .utf8) else { return }
        if descriptionDepth > 0 {
            descriptionBuffer += s
        } else if wantsText {
            text += s
        }
    }

    func parser(_: XMLParser, didEndElement elementName: String,
                namespaceURI _: String?, qualifiedName _: String?)
    // SwiftFormat owns brace placement and puts wrapped-signature braces on their own line.
    // swiftlint:disable:next opening_brace
    {
        if endElementWhileCapturingDescription(elementName) {
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let local = Self.localName(elementName)
        if !elementStack.isEmpty {
            elementStack.removeLast()
        }
        let parent = elementStack.last
        defer { text = "" }
        // Delegate cohesive element groups to helpers to keep this dispatcher's complexity low.
        guard !endNetworkLinkElement(local, trimmed: trimmed),
              !endGeometryElement(local),
              !endStyleElement(local, trimmed: trimmed),
              !endStyleMapElement(local, trimmed: trimmed, parent: parent),
              !endExtendedDataElement(local) else { return }
        switch local {
        case "Document", "Folder":
            containerStack.removeLast()
        case "name":
            // 1.7 keyed on the last `<name>` closed anywhere inside the placemark.
            placemark?.legacy.name = trimmed
            guard let parent, Self.nameParents.contains(parent) else { break }
            if parent == "Placemark" {
                placemark?.name = trimmed
            } else if parent == "NetworkLink" {
                networkLinkName = trimmed.isEmpty ? nil : trimmed
            } else if let c = containerStack.last, c !== rootBuilder {
                c.name = trimmed
            }
        case "Snippet", "snippet", "address", "phoneNumber":
            if parent == "Placemark" {
                storePlacemarkText(local, trimmed)
            }
        case "Placemark":
            if let pm = placemark {
                appendPlacemark(pm)
            }
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
        guard pm.legacy.isKept else { return }
        let coordinate = pm.hasPoint
            ? pm.coordinate
            : Self.firstCoordinate(of: pm.geometries) ?? pm.fallbackCoordinate
        let id = nextID("p")
        if let inline = pm.inlineStyle, !inline.isEmpty {
            pendingInlineStyles.append(PendingInlineStyle(placemarkID: id, fields: inline,
                                                          sharedStyleUrl: pm.styleUrl))
        }
        let built = KMLPlacemark(id: id, name: pm.name,
                                 descriptionHTML: pm.descriptionHTML,
                                 styleUrl: pm.styleUrl,
                                 coordinate: coordinate,
                                 hasPoint: pm.hasPoint,
                                 geometries: pm.geometries,
                                 extendedData: pm.extendedData,
                                 photoLinks: pm.photoLinks,
                                 sourceID: pm.sourceID,
                                 snippet: pm.snippet, address: pm.address,
                                 phoneNumber: pm.phoneNumber,
                                 stableKey: pm.legacy.stableKey(id: id, sourceID: pm.sourceID))
        containerStack.last?.placemarks.append(built)
    }

    /// First coordinate of the first geometry that has one — the representative point of a
    /// point-less geometry placemark.
    private static func firstCoordinate(of geometries: [KMLGeometry]) -> Coordinate? {
        for geometry in geometries {
            switch geometry {
            case let .point(coordinate):
                return coordinate
            case let .lineString(coords), let .track(coords):
                if let first = coords.first {
                    return first
                }
            case let .polygon(outer, _):
                if let first = outer.first {
                    return first
                }
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
            if descriptionDiscard {
                // Swallowed: not stored anywhere.
            } else if placemark != nil {
                placemark?.descriptionHTML = html
            } else if let c = containerStack.last, c !== rootBuilder {
                c.description = html
            }
            if !elementStack.isEmpty {
                elementStack.removeLast()
            }
            descriptionDiscard = false
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
