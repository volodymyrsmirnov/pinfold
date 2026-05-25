import CryptoKit
import Foundation

public struct KMLPlacemark: Equatable, Sendable, Identifiable {
    /// A parse-order identifier ("p1", "p2", …) assigned by the parser.
    /// **Not stable across re-parses** — if the source file changes, the same placemark
    /// may receive a different id on the next parse. Do not persist this value as a
    /// durable key; use it only for in-memory identity within a single parse session.
    public let id: String
    public let name: String?
    public let descriptionHTML: String?
    public let styleUrl: String?
    /// nil for a placeless placemark (no Point geometry).
    public let coordinate: Coordinate?
    public let extendedData: [KMLDataItem]
    /// Photo URLs gathered from ExtendedData `gx_media_links` (kept separate from extendedData).
    public let photoLinks: [String]
    /// The author-supplied `id` attribute from `<Placemark id="...">` in the source KML, if present.
    /// `nil` when the attribute was absent; empty string when the attribute was explicitly empty.
    public let sourceID: String?

    public init(id: String, name: String?, descriptionHTML: String?, styleUrl: String?,
                coordinate: Coordinate?, extendedData: [KMLDataItem], photoLinks: [String],
                sourceID: String? = nil) {
        self.id = id
        self.name = name
        self.descriptionHTML = descriptionHTML
        self.styleUrl = styleUrl
        self.coordinate = coordinate
        self.extendedData = extendedData
        self.photoLinks = photoLinks
        self.sourceID = sourceID
    }

    /// A durable identity for this placemark, safe to persist across re-parses.
    ///
    /// Fallback chain:
    /// 1. `"id:<sourceID>"` when the author supplied a non-empty `<Placemark id>`.
    /// 2. `"h:<hash>"` — a SHA-256 (16 hex chars) of `"<name>|<lat>|<lon>"`. Survives
    ///    folder reordering; only changes if this placemark's own name/coordinate change.
    /// 3. `"p:<id>"` — parse-order id, last resort for a placeless, nameless placemark.
    public var stableKey: String {
        if let sourceID, !sourceID.trimmingCharacters(in: .whitespaces).isEmpty {
            return "id:\(sourceID.trimmingCharacters(in: .whitespaces))"
        }
        let trimmedName = name?.trimmingCharacters(in: .whitespaces)
        let hasName = !(trimmedName?.isEmpty ?? true)
        if hasName || coordinate != nil {
            let lat = coordinate.map { String(format: "%.6f", $0.latitude + 0.0) } ?? ""
            let lon = coordinate.map { String(format: "%.6f", $0.longitude + 0.0) } ?? ""
            let basis = "\(trimmedName ?? "")|\(lat)|\(lon)"
            let digest = SHA256.hash(data: Data(basis.utf8))
            let hex = digest.map { String(format: "%02x", $0) }.joined().prefix(16)
            return "h:\(hex)"
        }
        return "p:\(id)"
    }
}
