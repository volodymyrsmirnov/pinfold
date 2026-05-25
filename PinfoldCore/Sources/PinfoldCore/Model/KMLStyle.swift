public struct KMLStyle: Equatable, Sendable {
    public let id: String
    /// Icon image URL/href as written in the KML (remote URL or KMZ-relative path).
    public let iconHref: String?
    /// KML color string in aabbggrr hex order, or nil.
    public let iconColor: String?
    public let iconScale: Double?

    public init(id: String, iconHref: String?, iconColor: String?, iconScale: Double?) {
        self.id = id
        self.iconHref = iconHref
        self.iconColor = iconColor
        self.iconScale = iconScale
    }
}
