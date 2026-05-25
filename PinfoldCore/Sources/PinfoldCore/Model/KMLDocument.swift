public struct KMLDocument: Equatable, Sendable {
    public let name: String?
    public let descriptionHTML: String?
    public let root: KMLContainer
    /// Styles by id (without leading '#').
    public let styles: [String: KMLStyle]
    /// StyleMap id -> the 'normal' styleUrl it points to (e.g. "#normalStyle").
    public let styleMaps: [String: String]

    public init(name: String?, descriptionHTML: String?, root: KMLContainer,
                styles: [String: KMLStyle], styleMaps: [String: String]) {
        self.name = name
        self.descriptionHTML = descriptionHTML
        self.root = root
        self.styles = styles
        self.styleMaps = styleMaps
    }

    public var placemarkCount: Int { root.allPlacemarks.count }
    public var pointCount: Int { root.allPlacemarks.filter { $0.coordinate != nil }.count }

    /// Resolves a styleUrl (e.g. "#foo") to a KMLStyle, following one StyleMap hop to its
    /// 'normal' style if needed. Returns nil if unknown.
    public func resolvedStyle(forStyleUrl styleUrl: String?) -> KMLStyle? {
        guard let key = Self.localId(from: styleUrl) else { return nil }
        if let direct = styles[key] { return direct }
        if let mappedUrl = styleMaps[key], let mappedKey = Self.localId(from: mappedUrl) {
            return styles[mappedKey]
        }
        return nil
    }

    /// Strips a leading '#' from a local style reference. Returns nil for nil/empty input.
    private static func localId(from styleUrl: String?) -> String? {
        guard let s = styleUrl, !s.isEmpty else { return nil }
        return s.hasPrefix("#") ? String(s.dropFirst()) : s
    }
}
