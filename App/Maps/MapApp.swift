import Foundation

// MARK: - MapApp

/// A single entry in the map-app roster.
///
/// `MapApp` describes one third-party (or built-in) mapping application: its stable
/// identifier, display name, URL scheme used for installed-app detection, and a closure
/// that builds a deep-link URL for a named coordinate.
///
/// **URL formats are best-effort.** The deep-link schemes are based on each app's
/// publicly documented URL scheme at the time of writing and may change without notice.
/// There is no official SDK contract for any of these schemes; treat them as best-effort
/// approximations.
///
/// **macOS caveat.** When running as "Designed for iPad" on Apple Silicon Macs,
/// `canOpenURL` detection for non-Apple map apps is unreliable because third-party iOS
/// apps are generally not installed on macOS. Apple Maps (`alwaysAvailable: true`) is
/// always shown; detection results for the remaining 11 apps should not be trusted on
/// macOS.
public struct MapApp: Identifiable, Sendable, Hashable {
    // MARK: - Properties

    /// Stable lowercase identifier, e.g. `"apple"`, `"google"`, `"waze"`.
    public let id: String

    /// Human-readable name shown in the map picker UI.
    public let displayName: String

    /// URL scheme string used with `canOpenURL` to detect whether the app is installed,
    /// e.g. `"comgooglemaps"`. `nil` for Apple Maps, which is always available.
    public let urlScheme: String?

    /// `true` when the app is always available regardless of `canOpenURL` result.
    /// Only Apple Maps carries this flag.
    public let alwaysAvailable: Bool

    // MARK: - URL builder

    /// Builds a deep-link `URL` that drops a labeled pin at the given coordinate.
    ///
    /// - Parameters:
    ///   - latitude: WGS-84 latitude in decimal degrees.
    ///   - longitude: WGS-84 longitude in decimal degrees.
    ///   - name: Human-readable pin label. URL-encoded before inclusion.
    /// - Returns: A launch URL for this app, or `nil` if the URL cannot be constructed.
    public let makeURL: @Sendable (_ latitude: Double, _ longitude: Double, _ name: String) -> URL?

    // MARK: - Hashable / Equatable

    public static func == (lhs: MapApp, rhs: MapApp) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Roster

extension MapApp {
    /// The full roster of 12 supported map apps.
    ///
    /// Ordered with Apple Maps first (always available), followed by third-party apps in
    /// alphabetical order of their `id`. When displaying installed apps, filter this list
    /// with `alwaysAvailable || canOpenURL(scheme)`.
    public static let roster: [MapApp] = [
        apple,
        google,
        waze,
        organic,
        mapsme,
        osmand,
        magicearth,
        citymapper,
        yandex,
        twogis,
        sygic,
        guru,
    ]

    // MARK: - Individual entries

    /// Apple Maps — always installed; uses the `https://maps.apple.com` universal link.
    static let apple = MapApp(
        id: "apple",
        displayName: "Apple Maps",
        urlScheme: nil,
        alwaysAvailable: true
    ) { lat, lng, name in
        var components = URLComponents(string: "https://maps.apple.com/")!
        components.queryItems = [
            URLQueryItem(name: "ll", value: "\(lat),\(lng)"),
            URLQueryItem(name: "q", value: name),
        ]
        return components.url
    }

    /// Google Maps for iOS.
    static let google = MapApp(
        id: "google",
        displayName: "Google Maps",
        urlScheme: "comgooglemaps",
        alwaysAvailable: false
    ) { lat, lng, _ in
        var components = URLComponents(string: "comgooglemaps://")!
        components.queryItems = [
            URLQueryItem(name: "q", value: "\(lat),\(lng)"),
            URLQueryItem(name: "center", value: "\(lat),\(lng)"),
        ]
        return components.url
    }

    /// Waze navigation.
    static let waze = MapApp(
        id: "waze",
        displayName: "Waze",
        urlScheme: "waze",
        alwaysAvailable: false
    ) { lat, lng, _ in
        var components = URLComponents(string: "waze://")!
        components.queryItems = [
            URLQueryItem(name: "ll", value: "\(lat),\(lng)"),
            URLQueryItem(name: "navigate", value: "yes"),
        ]
        return components.url
    }

    /// Organic Maps (successor to Maps.me with a different bundle).
    static let organic = MapApp(
        id: "organic",
        displayName: "Organic Maps",
        urlScheme: "om",
        alwaysAvailable: false
    ) { lat, lng, name in
        var components = URLComponents(string: "om://map")!
        components.queryItems = [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "ll", value: "\(lat),\(lng)"),
            URLQueryItem(name: "n", value: name),
        ]
        return components.url
    }

    /// Maps.me.
    static let mapsme = MapApp(
        id: "mapsme",
        displayName: "Maps.me",
        urlScheme: "mapsme",
        alwaysAvailable: false
    ) { lat, lng, name in
        var components = URLComponents(string: "mapsme://map")!
        components.queryItems = [
            URLQueryItem(name: "ll", value: "\(lat),\(lng)"),
            URLQueryItem(name: "n", value: name),
        ]
        return components.url
    }

    /// OsmAnd.
    static let osmand = MapApp(
        id: "osmand",
        displayName: "OsmAnd",
        urlScheme: "osmandmaps",
        alwaysAvailable: false
    ) { lat, lng, _ in
        var components = URLComponents(string: "osmandmaps://")!
        components.queryItems = [
            URLQueryItem(name: "lat", value: "\(lat)"),
            URLQueryItem(name: "lon", value: "\(lng)"),
            URLQueryItem(name: "z", value: "16"),
        ]
        return components.url
    }

    /// Magic Earth navigation.
    static let magicearth = MapApp(
        id: "magicearth",
        displayName: "Magic Earth",
        urlScheme: "magicearth",
        alwaysAvailable: false
    ) { lat, lng, name in
        var components = URLComponents(string: "magicearth://")!
        components.queryItems = [
            URLQueryItem(name: "drive_to", value: nil),
            URLQueryItem(name: "lat", value: "\(lat)"),
            URLQueryItem(name: "lon", value: "\(lng)"),
            URLQueryItem(name: "name", value: name),
        ]
        return components.url
    }

    /// Citymapper urban transit.
    static let citymapper = MapApp(
        id: "citymapper",
        displayName: "Citymapper",
        urlScheme: "citymapper",
        alwaysAvailable: false
    ) { lat, lng, name in
        var components = URLComponents(string: "citymapper://directions")!
        components.queryItems = [
            URLQueryItem(name: "endcoord", value: "\(lat),\(lng)"),
            URLQueryItem(name: "endname", value: name),
        ]
        return components.url
    }

    /// Yandex Maps — note that the coordinate order in the `pt` parameter is lng,lat.
    static let yandex = MapApp(
        id: "yandex",
        displayName: "Yandex Maps",
        urlScheme: "yandexmaps",
        alwaysAvailable: false
    ) { lat, lng, _ in
        var components = URLComponents(string: "yandexmaps://maps.yandex.ru/")!
        components.queryItems = [
            URLQueryItem(name: "pt", value: "\(lng),\(lat)"),
            URLQueryItem(name: "z", value: "16"),
        ]
        return components.url
    }

    /// 2GIS — note that the coordinate order in the path is lng,lat.
    static let twogis = MapApp(
        id: "twogis",
        displayName: "2GIS",
        urlScheme: "dgis",
        alwaysAvailable: false
    ) { lat, lng, _ in
        URL(string: "dgis://2gis.ru/geo/\(lng),\(lat)")
    }

    /// Sygic — uses `|`-delimited path components; note coordinate order is lng,lat.
    ///
    /// The pipe characters in the URL path are not valid unencoded in a URL string, so
    /// they are pre-encoded to `%7C` before passing to `URL(string:)`. The launched URL
    /// is interpreted correctly by Sygic regardless of whether the pipes are literal or
    /// percent-encoded.
    static let sygic = MapApp(
        id: "sygic",
        displayName: "Sygic",
        urlScheme: "com.sygic.aura",
        alwaysAvailable: false
    ) { lat, lng, _ in
        URL(string: "com.sygic.aura://coordinate%7C\(lng)%7C\(lat)%7Cshow")
    }

    /// Guru Maps — the `guru://show` endpoint has no label parameter, so the pin name is dropped.
    static let guru = MapApp(
        id: "guru",
        displayName: "Guru Maps",
        urlScheme: "guru",
        alwaysAvailable: false
    ) { lat, lng, _ in
        var components = URLComponents(string: "guru://show")!
        components.queryItems = [
            URLQueryItem(name: "place", value: "\(lat),\(lng)"),
        ]
        return components.url
    }
}
