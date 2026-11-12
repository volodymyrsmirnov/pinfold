import Foundation

/// Element-group dispatchers for the SAX delegate. `didStartElement`/`didEndElement` delegate
/// each cohesive group (geometry, style, style-map, extended-data) to one of these so the
/// dispatchers themselves stay small. Each `end…`/`start…` returns true when the element
/// belonged to its group. Kept in a separate file to keep `KMLParserDelegate`'s body focused.
extension KMLParserDelegate {
    /// Opens geometry elements (Point/LineString/Polygon rings/Track), seeding their buffers.
    func startGeometryElement(_ local: String) -> Bool {
        switch local {
        case "Point":
            placemark?.legacy.hasPoint = true
            inPoint = true
        case "LineString":
            if placemark != nil {
                inLineString = true
                lineStringCoords = []
                placemark?.legacy.lineFirst = nil
            }
        case "Polygon":
            if placemark != nil {
                inPolygon = true
                polygonOuter = []
                polygonInners = []
                placemark?.legacy.outerFirst = nil
            }
        case "outerBoundaryIs":
            if inPolygon {
                inOuterBoundary = true
            }
        case "innerBoundaryIs":
            if inPolygon {
                inInnerBoundary = true
                currentInnerRing = []
            }
        case "Track":
            if placemark != nil {
                inTrack = true
                trackCoords = []
            }
        case "Model", "MultiTrack":
            // Geometry types we don't capture themselves; 1.7 dropped a point-less placemark
            // whose only geometry was one (gx:MultiTrack's inner Tracks are still captured).
            placemark?.legacy.hasUncapturedGeometry = true
        default:
            return false
        }
        return true
    }

    /// Closes geometry elements (Point/LineString/Polygon rings/Track and their coordinates).
    func endGeometryElement(_ local: String) -> Bool {
        switch local {
        case "Point":
            inPoint = false
        case "coordinates":
            handleCoordinatesEnd()
        case "coord":
            // gx:coord — one space-separated "lon lat [alt]" triple appended to the track.
            if inTrack, let c = Self.parseTrackCoord(text) {
                trackCoords.append(c)
            }
        case "LineString":
            if inLineString {
                closeLegacyGeometry(first: placemark?.legacy.lineFirst)
                appendLine(lineStringCoords, asTrack: false)
                inLineString = false
                lineStringCoords = []
            }
        case "outerBoundaryIs":
            inOuterBoundary = false
        case "innerBoundaryIs":
            if inInnerBoundary {
                // A degenerate inner ring is dropped alone; the polygon survives.
                if currentInnerRing.count >= Self.minRingVertices {
                    polygonInners.append(currentInnerRing)
                }
                inInnerBoundary = false
                currentInnerRing = []
            }
        case "Polygon":
            if inPolygon {
                closeLegacyGeometry(first: placemark?.legacy.outerFirst)
                if polygonOuter.count >= Self.minRingVertices {
                    placemark?.geometries.append(.polygon(outer: polygonOuter, inners: polygonInners))
                } else if let first = polygonOuter.first, placemark?.fallbackCoordinate == nil {
                    // A degenerate polygon is dropped but still locates the placemark.
                    placemark?.fallbackCoordinate = first
                }
                inPolygon = false
                polygonOuter = []
                polygonInners = []
            }
        case "Track":
            if inTrack {
                closeLegacyGeometry(first: trackCoords.first)
                appendLine(trackCoords, asTrack: true)
                inTrack = false
                trackCoords = []
            }
        default:
            return false
        }
        return true
    }

    private func closeLegacyGeometry(first: Coordinate?) {
        placemark?.legacy.closeGeometry(first: first)
    }

    /// Fewest vertices of a line or track worth keeping.
    static let minLineVertices = 2
    /// Fewest vertices of a polygon ring worth keeping.
    static let minRingVertices = 3

    /// Appends a line or track when it has enough vertices. A single-vertex one is dropped
    /// but donates its coordinate so the placemark can still be located on a map.
    private func appendLine(_ coords: [Coordinate], asTrack: Bool) {
        if coords.count >= Self.minLineVertices {
            placemark?.geometries.append(asTrack ? .track(coords) : .lineString(coords))
        } else if let only = coords.first, placemark?.fallbackCoordinate == nil {
            placemark?.fallbackCoordinate = only
        }
    }

    /// Closes Style sub-elements (Icon/Line/Poly fields and the Style itself).
    func endStyleElement(_ local: String, trimmed: String) -> Bool {
        switch local {
        case "color":
            if styleBuilder?.inIconStyle == true {
                styleBuilder?.iconColor = trimmed
            } else if styleBuilder?.inLineStyle == true {
                styleBuilder?.lineColor = trimmed
            } else if styleBuilder?.inPolyStyle == true {
                styleBuilder?.polyColor = trimmed
            }
        case "width":
            if styleBuilder?.inLineStyle == true {
                styleBuilder?.lineWidth = Double(trimmed)
            }
        case "fill":
            if styleBuilder?.inPolyStyle == true {
                styleBuilder?.polyFill = (trimmed == "1" || trimmed == "true")
            }
        case "scale":
            if styleBuilder?.inIconStyle == true {
                styleBuilder?.iconScale = Double(trimmed)
            }
        case "href":
            if styleBuilder?.inIconStyle == true {
                styleBuilder?.iconHref = trimmed
            }
        case "IconStyle":
            styleBuilder?.inIconStyle = false
        case "LineStyle":
            styleBuilder?.inLineStyle = false
        case "PolyStyle":
            styleBuilder?.inPolyStyle = false
        case "Style":
            closeStyleElement()
        default:
            return false
        }
        return true
    }

    /// Indexes the assembled `<Style>` and, if it sits inside a StyleMap `<Pair>`, records it
    /// as that pair's style reference.
    private func closeStyleElement() {
        if let b = styleBuilder, placemark != nil {
            // Inline style: belongs to the placemark (or to the open Pair of an inline StyleMap).
            if inPair {
                pairInlineStyle = StyleFields(b)
            } else {
                placemark?.inlineStyle = StyleFields(b)
            }
        } else if let b = styleBuilder {
            styles[b.id] = KMLStyle(id: b.id, iconHref: b.iconHref,
                                    iconColor: b.iconColor, iconScale: b.iconScale,
                                    lineColor: b.lineColor, lineWidth: b.lineWidth,
                                    polyColor: b.polyColor, polyFill: b.polyFill)
            // An inline <Style> inside a StyleMap <Pair> acts as that pair's style reference,
            // equivalent to a <styleUrl> pointing at its (possibly synthesized) id.
            if inPair {
                pairStyleURL = "#\(b.id)"
            }
        }
        styleBuilder = nil
    }

    /// Closes StyleMap-related elements (key/styleUrl/Pair/StyleMap). `styleUrl` inside a
    /// placemark is handled here too since it shares the element name.
    func endStyleMapElement(_ local: String, trimmed: String, parent: String?) -> Bool {
        switch local {
        case "key":
            if inPair {
                pairKey = trimmed
            }
        case "styleUrl":
            if parent == "Placemark" {
                placemark?.styleUrl = trimmed
            } else if parent == "Pair", inPair {
                pairStyleURL = trimmed
            }
        case "Pair":
            // Resolve only on close: KML allows <key> before or after the style reference.
            if pairKey == "normal" {
                if let url = pairStyleURL {
                    styleMapNormalURL = url
                }
                if placemark != nil {
                    applyInlinePair()
                }
            }
            inPair = false; pairKey = nil; pairStyleURL = nil; pairInlineStyle = nil
        case "StyleMap":
            if let id = styleMapID, let normal = styleMapNormalURL {
                styleMaps[id] = normal
            }
            inStyleMap = false
            styleMapID = nil; styleMapNormalURL = nil
        default:
            return false
        }
        return true
    }

    /// Applies the normal pair of an inline `<StyleMap>` to the open placemark: an inline
    /// style becomes its inline style, a `<styleUrl>` its style reference unless it has one.
    private func applyInlinePair() {
        if let inline = pairInlineStyle {
            placemark?.inlineStyle = inline
        } else if let url = pairStyleURL, placemark?.styleUrl == nil {
            placemark?.styleUrl = url
        }
    }

    /// Closes ExtendedData elements (ExtendedData/value/SimpleData/Data).
    func endExtendedDataElement(_ local: String) -> Bool {
        switch local {
        case "ExtendedData":
            inExtendedData = false
        case "value":
            // Only meaningful inside an open <Data>; a stray <value> elsewhere in
            // <ExtendedData> must not leak into the next data item.
            if inExtendedData, inDataElement {
                currentDataValue = text
            }
        case "SimpleData":
            if let name = currentSimpleDataName {
                appendDataItem(name: name, value: text.trimmingCharacters(in: .whitespacesAndNewlines),
                               displayName: nil)
            }
            currentSimpleDataName = nil
        case "displayName":
            if inDataElement {
                let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
                currentDataDisplayName = name.isEmpty ? nil : name
            }
        case "Data":
            closeDataElement()
        default:
            return false
        }
        return true
    }

    /// Flushes a `<Data>` element into the placemark: `gx_media_links` become photo links,
    /// everything else an extended-data item.
    private func closeDataElement() {
        if let name = currentDataName {
            let value = currentDataValue ?? ""
            if name == "gx_media_links" {
                let links = value
                    .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
                    .map(String.init)
                placemark?.photoLinks.append(contentsOf: links)
            } else {
                appendDataItem(name: name, value: value.trimmingCharacters(in: .whitespacesAndNewlines),
                               displayName: currentDataDisplayName)
            }
        }
        inDataElement = false
        currentDataName = nil; currentDataValue = nil; currentDataDisplayName = nil
    }

    /// Appends an item with an id unique within the placemark (`name`, `name#2`, ...).
    private func appendDataItem(name: String, value: String, displayName: String?) {
        guard let existing = placemark?.extendedData else { return }
        let taken = Set(existing.map(\.id))
        var id = name
        var n = 1
        while taken.contains(id) {
            n += 1
            id = "\(name)#\(n)"
        }
        placemark?.extendedData.append(KMLDataItem(name: name, value: value,
                                                   displayName: displayName, id: id))
    }

    /// Stores a `Snippet`/`address`/`phoneNumber` text on the open placemark; empty is nil.
    func storePlacemarkText(_ local: String, _ value: String) {
        let text = value.isEmpty ? nil : value
        switch local {
        case "address": placemark?.address = text
        case "phoneNumber": placemark?.phoneNumber = text
        default: placemark?.snippet = text
        }
    }

    /// Routes a closing `<coordinates>` element's text to the active geometry buffer, or to
    /// the placemark's Point coordinate when inside a `<Point>`.
    private func handleCoordinatesEnd() {
        guard placemark != nil else { return }
        if inPoint {
            // Only capture coordinates while inside a <Point> so that LineString/Polygon
            // vertices in the same placemark don't clobber the Point coordinate.
            placemark?.legacy.pointCoordinate = LegacyCoordinate.firstTuple(text)
            // A Point whose coordinates do not parse is not a point: it must neither set
            // `hasPoint` nor displace a valid one.
            if let point = Coordinate(parsingFirstTuple: text) {
                if placemark?.hasPoint == true {
                    // MultiGeometry: the first valid point stays the representative one.
                    placemark?.geometries.append(.point(point))
                } else {
                    placemark?.coordinate = point
                    placemark?.hasPoint = true
                }
            }
        } else if inLineString {
            lineStringCoords = Coordinate.parseList(text)
            placemark?.legacy.lineFirst = LegacyCoordinate.list(text).first
        } else if inInnerBoundary {
            currentInnerRing = Coordinate.parseList(text)
        } else if inOuterBoundary {
            polygonOuter = Coordinate.parseList(text)
            placemark?.legacy.outerFirst = LegacyCoordinate.list(text).first
        }
    }

    /// Parses one `<gx:coord>` triple: space-separated "lon lat [alt]" (note the order and
    /// separator differ from comma-separated `<coordinates>`).
    static func parseTrackCoord(_ raw: String) -> Coordinate? {
        let parts = raw
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
            .map(String.init)
        guard parts.count >= 2, let lon = Double(parts[0]), let lat = Double(parts[1]),
              lon.isFinite, lat.isFinite else { return nil }
        let alt = parts.count >= 3 ? Double(parts[2]) : nil
        return Coordinate(longitude: lon, latitude: lat,
                          altitude: (alt?.isFinite ?? false) ? alt : nil)
    }
}
