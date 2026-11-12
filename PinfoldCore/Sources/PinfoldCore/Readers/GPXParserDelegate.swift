import Foundation

/// SAX delegate for `GPXReader`. Text is only captured for the leaf elements the mapping uses,
/// found by their exact path under `gpx`, so `extensions` content can never leak into fields.
final class GPXParserDelegate: NSObject, XMLParserDelegate {
    private enum Kind: String { case wpt, trk, rte }

    /// One `wpt`/`trk`/`rte` under construction.
    private struct Item {
        let kind: Kind
        var coordinate: Coordinate?
        var fields: [String: String] = [:]
        var linkHref: String?
        var segments: [[Coordinate]] = []
        var points: [Coordinate] = []
    }

    private static let maxTextBytes = 64 * 1024
    private static let leafPaths: Set<String> = {
        var paths: Set = ["gpx/metadata/name", "gpx/metadata/desc",
                          "gpx/trk/trkseg/trkpt/ele", "gpx/rte/rtept/ele"]
        for kind in ["wpt", "trk", "rte"] {
            for field in ["name", "desc", "cmt", "type", "sym", "time", "url", "urlname", "link/text"] {
                paths.insert("gpx/\(kind)/\(field)")
            }
        }
        paths.insert("gpx/wpt/ele")
        return paths
    }()

    /// Set to abort parsing; `GPXReader` rethrows it.
    private(set) var abortError: Error?

    private var path: [String] = []
    private var text = ""
    private var capturing = false
    private var startCount = 0
    private var idCounter = 0
    private var item: Item?
    private var pointCoordinate: Coordinate?
    private var pointElevation: Double?
    private var segment: [Coordinate] = []
    private var documentName: String?
    private var documentDescription: String?
    private var waypoints: [KMLPlacemark] = []
    private var tracks: [KMLPlacemark] = []
    private var routes: [KMLPlacemark] = []

    private func abort(_ parser: XMLParser, with error: Error) {
        abortError = error
        parser.abortParsing()
    }

    // MARK: DTD declarations (defence in depth behind the byte-level DOCTYPE guard)

    private func rejectDeclaration(_ parser: XMLParser) {
        abort(parser, with: KMLParseError.dtdProhibited)
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

    // MARK: Elements

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI _: String?,
                qualifiedName _: String?, attributes attributeDict: [String: String] = [:])
    // swiftlint:disable:next opening_brace
    {
        startCount += 1
        if startCount.isMultiple(of: 256), Task.isCancelled {
            abort(parser, with: CancellationError())
            return
        }
        path.append(elementName)
        if path.count == 1, elementName != "gpx" {
            abort(parser, with: KMLParseError.unsupportedRootElement(elementName))
            return
        }
        let key = path.joined(separator: "/")
        text = ""
        capturing = Self.leafPaths.contains(key)
        switch key {
        case "gpx/wpt": item = Item(kind: .wpt, coordinate: Self.coordinate(attributeDict))
        case "gpx/trk": item = Item(kind: .trk)
        case "gpx/rte": item = Item(kind: .rte)
        case "gpx/trk/trkseg": segment = []
        case "gpx/trk/trkseg/trkpt", "gpx/rte/rtept":
            pointCoordinate = Self.coordinate(attributeDict)
            pointElevation = nil
        case "gpx/wpt/link", "gpx/trk/link", "gpx/rte/link": item?.linkHref = attributeDict["href"]
        default: break
        }
    }

    func parser(_: XMLParser, foundCharacters string: String) {
        if capturing, text.utf8.count < Self.maxTextBytes {
            text += string
        }
    }

    func parser(_: XMLParser, foundCDATA CDATABlock: Data) {
        if capturing, text.utf8.count < Self.maxTextBytes, let string = String(bytes: CDATABlock, encoding: .utf8) {
            text += string
        }
    }

    func parser(_: XMLParser, didEndElement _: String, namespaceURI _: String?, qualifiedName _: String?) {
        guard !path.isEmpty else { return }
        let key = path.joined(separator: "/")
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if capturing, !value.isEmpty {
            store(value, forPath: key)
        }
        capturing = false
        text = ""
        switch key {
        case "gpx/wpt", "gpx/trk", "gpx/rte": finishItem()
        case "gpx/trk/trkseg": item?.segments.append(segment)
        case "gpx/trk/trkseg/trkpt": finishPoint(intoSegment: true)
        case "gpx/rte/rtept": finishPoint(intoSegment: false)
        default: break
        }
        path.removeLast()
    }

    private func store(_ value: String, forPath key: String) {
        switch key {
        case "gpx/metadata/name": documentName = value
        case "gpx/metadata/desc": documentDescription = value
        case "gpx/trk/trkseg/trkpt/ele", "gpx/rte/rtept/ele": pointElevation = Self.finite(value)
        case "gpx/wpt/ele":
            if let coordinate = item?.coordinate, let elevation = Self.finite(value) {
                item?.coordinate = Coordinate(longitude: coordinate.longitude, latitude: coordinate.latitude,
                                              altitude: elevation)
            }
        default:
            let field = key.split(separator: "/").dropFirst(2).joined()
            item?.fields[field] = value
        }
    }

    // MARK: Building

    private func finishPoint(intoSegment: Bool) {
        guard let base = pointCoordinate else { return }
        let point = Coordinate(longitude: base.longitude, latitude: base.latitude, altitude: pointElevation)
        if intoSegment {
            segment.append(point)
        } else {
            item?.points.append(point)
        }
        pointCoordinate = nil
    }

    private func finishItem() {
        guard let finished = item else { return }
        item = nil
        switch finished.kind {
        case .wpt:
            // A waypoint without a valid position has nothing to show.
            guard finished.coordinate != nil else { return }
            waypoints.append(placemark(finished, coordinate: finished.coordinate, hasPoint: true, geometries: []))
        case .trk:
            let tracks = finished.segments.filter { !$0.isEmpty }.map(KMLGeometry.track)
            self.tracks.append(placemark(finished, coordinate: finished.segments.lazy.compactMap(\.first).first,
                                         hasPoint: false, geometries: tracks))
        case .rte:
            let line: [KMLGeometry] = finished.points.isEmpty ? [] : [.lineString(finished.points)]
            routes.append(placemark(finished, coordinate: finished.points.first, hasPoint: false, geometries: line))
        }
    }

    private func placemark(_ item: Item, coordinate: Coordinate?, hasPoint: Bool,
                           geometries: [KMLGeometry]) -> KMLPlacemark
    {
        idCounter += 1
        let usesComment = item.fields["desc"] == nil
        var data: [KMLDataItem] = []
        for field in ["sym", "type", "time"] + (usesComment ? [] : ["cmt"]) {
            if let value = item.fields[field] {
                data.append(KMLDataItem(name: field, value: value))
            }
        }
        return KMLPlacemark(id: "p\(idCounter)", name: item.fields["name"],
                            descriptionHTML: Self.descriptionHTML(item),
                            styleUrl: nil, coordinate: coordinate, hasPoint: hasPoint, geometries: geometries,
                            extendedData: data, photoLinks: [])
    }

    func makeDocument() -> KMLDocument {
        let populated = [("waypoints", "Waypoints", waypoints), ("tracks", "Tracks", tracks),
                         ("routes", "Routes", routes)].filter { !$0.2.isEmpty }
        let root: KMLContainer
        if populated.count > 1 {
            let folders = populated.map {
                KMLContainer(id: $0.0, name: $0.1, children: [], placemarks: $0.2)
            }
            root = KMLContainer(id: "root", name: nil, children: folders, placemarks: [])
        } else {
            root = KMLContainer(id: "root", name: nil, children: [], placemarks: populated.first?.2 ?? [])
        }
        return KMLDocument(name: documentName, descriptionHTML: documentDescription.map(Self.escape),
                           root: root, styles: [:], styleMaps: [:])
    }

    // MARK: Helpers

    private static func coordinate(_ attributes: [String: String]) -> Coordinate? {
        guard let lat = attributes["lat"].flatMap(finite), let lon = attributes["lon"].flatMap(finite),
              (-90.0 ... 90.0).contains(lat), (-180.0 ... 180.0).contains(lon) else { return nil }
        return Coordinate(longitude: lon, latitude: lat)
    }

    private static func finite(_ string: String) -> Double? {
        Double(string).flatMap { $0.isFinite ? $0 : nil }
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// `desc` (else `cmt`) as escaped text, then the `link` (or GPX 1.0 `url`) as an anchor when
    /// it is an http(s) address.
    private static func descriptionHTML(_ item: Item) -> String? {
        var parts: [String] = []
        if let text = item.fields["desc"] ?? item.fields["cmt"] {
            parts.append(escape(text))
        }
        let href = item.linkHref ?? item.fields["url"]
        if let href, let url = URL(string: href), ["http", "https"].contains(url.scheme?.lowercased()) {
            let label = item.fields["linktext"] ?? item.fields["urlname"] ?? href
            parts.append("<a href=\"\(escape(href))\">\(escape(label))</a>")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "<br>")
    }
}
