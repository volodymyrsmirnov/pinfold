/// The on-disk format a document was read from.
public enum SourceFormat: String, Sendable {
    case kml
    case kmz
    case gpx
    case geoJSON
}
