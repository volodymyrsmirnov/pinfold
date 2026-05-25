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

    public init(id: String, name: String?, descriptionHTML: String?, styleUrl: String?,
                coordinate: Coordinate?, extendedData: [KMLDataItem], photoLinks: [String]) {
        self.id = id
        self.name = name
        self.descriptionHTML = descriptionHTML
        self.styleUrl = styleUrl
        self.coordinate = coordinate
        self.extendedData = extendedData
        self.photoLinks = photoLinks
    }
}
