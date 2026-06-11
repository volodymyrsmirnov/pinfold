public struct KMLStyle: Equatable, Sendable {
    public let id: String
    /// Icon image URL/href as written in the KML (remote URL or KMZ-relative path).
    public let iconHref: String?
    /// KML color string in aabbggrr hex order, or nil.
    public let iconColor: String?
    public let iconScale: Double?
    /// LineStyle color (KML aabbggrr hex string), or nil.
    public let lineColor: String?
    /// LineStyle width in pixels, or nil.
    public let lineWidth: Double?
    /// PolyStyle fill color (KML aabbggrr hex string), or nil.
    public let polyColor: String?
    /// PolyStyle `<fill>` flag (whether the polygon interior is filled), or nil.
    public let polyFill: Bool?

    public init(id: String, iconHref: String?, iconColor: String?, iconScale: Double?,
                lineColor: String? = nil, lineWidth: Double? = nil,
                polyColor: String? = nil, polyFill: Bool? = nil)
    // SwiftFormat puts the brace of a wrapped multi-line signature on its own line.
    // swiftlint:disable:next opening_brace
    {
        self.id = id
        self.iconHref = iconHref
        self.iconColor = iconColor
        self.iconScale = iconScale
        self.lineColor = lineColor
        self.lineWidth = lineWidth
        self.polyColor = polyColor
        self.polyFill = polyFill
    }
}
