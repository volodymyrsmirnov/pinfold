import Foundation

/// A `<NetworkLink>` the document points at: another KML/KMZ to fetch, as written in the file.
public struct KMLNetworkLink: Equatable, Sendable {
    public let name: String?
    public let href: String
    /// `<refreshMode>` of the `<Link>`/`<Url>`; nil when absent or not a known value.
    public let refreshMode: KMLRefreshMode?
    /// `<refreshInterval>` in seconds; nil when absent or not numeric.
    public let refreshInterval: TimeInterval?

    public init(name: String?, href: String,
                refreshMode: KMLRefreshMode? = nil, refreshInterval: TimeInterval? = nil)
    // swiftlint:disable:next opening_brace
    {
        self.name = name
        self.href = href
        self.refreshMode = refreshMode
        self.refreshInterval = refreshInterval
    }
}

/// A `<Link>`'s `<refreshMode>`.
public enum KMLRefreshMode: String, Sendable, Equatable, Codable {
    case onChange, onInterval, onExpire
}

/// The file-level `<NetworkLinkControl>` hints. `<Update>` blocks are ignored.
public struct KMLNetworkLinkControl: Equatable, Sendable {
    public let minRefreshPeriod: TimeInterval?
    public let expires: Date?

    public init(minRefreshPeriod: TimeInterval?, expires: Date?) {
        self.minRefreshPeriod = minRefreshPeriod
        self.expires = expires
    }
}

public struct KMLDocument: Equatable, Sendable {
    public let name: String?
    public let descriptionHTML: String?
    public let root: KMLContainer
    /// Styles by id (without leading '#').
    public let styles: [String: KMLStyle]
    /// StyleMap id -> the 'normal' styleUrl it points to (e.g. "#normalStyle").
    public let styleMaps: [String: String]
    /// Network links in document order, across all nesting levels. Empty hrefs are skipped.
    public let networkLinks: [KMLNetworkLink]
    /// The `<NetworkLinkControl>` hints, nil when the file has none.
    public let networkLinkControl: KMLNetworkLinkControl?

    public init(name: String?, descriptionHTML: String?, root: KMLContainer,
                styles: [String: KMLStyle], styleMaps: [String: String],
                networkLinks: [KMLNetworkLink] = [], networkLinkControl: KMLNetworkLinkControl? = nil)
    // SwiftFormat puts the brace of a wrapped multi-line signature on its own line.
    // swiftlint:disable:next opening_brace
    {
        self.name = name
        self.descriptionHTML = descriptionHTML
        self.root = root
        self.styles = styles
        self.styleMaps = styleMaps
        self.networkLinks = networkLinks
        self.networkLinkControl = networkLinkControl
    }

    public var placemarkCount: Int {
        root.placemarkCount
    }

    /// Number of placemarks with an explicit `<Point>` geometry. A point-less placemark that
    /// carries only line/polygon/track geometry has a representative `coordinate` but is NOT
    /// counted here.
    public var pointCount: Int {
        root.pointCount
    }

    /// Resolves a styleUrl (e.g. "#foo") to a KMLStyle, following one StyleMap hop to its
    /// 'normal' style if needed. Returns nil if unknown.
    public func resolvedStyle(forStyleUrl styleUrl: String?) -> KMLStyle? {
        guard let key = Self.localId(from: styleUrl) else { return nil }
        if let direct = styles[key] {
            return direct
        }
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
