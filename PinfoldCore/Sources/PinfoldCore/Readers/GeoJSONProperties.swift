import Foundation

/// Style identity used to deduplicate synthesized styles (KML colours are `aabbggrr`).
struct GeoJSONStyleKey: Hashable {
    var iconHref: String?
    var iconColor: String?
    var iconScale: Double?
    var lineColor: String?
    var lineWidth: Double?
    var polyColor: String?
}

/// Feature `properties` mapped to placemark fields: `name` (else `title`), `description`,
/// `snippet`, `address`, `phoneNumber` (else `phone`), photo URLs, simplestyle keys and a
/// remote `icon` URL (-> style), and everything else as sorted extended data.
struct GeoJSONProperties {
    /// Simplestyle keys always consumed by the style, even when their value is unusable.
    /// `marker-symbol` (a Maki icon name) is not among them: no icon set ships with the app,
    /// so it stays visible as data rather than vanishing.
    private static let styleKeys: Set<String> = [
        "marker-color", "marker-size", "stroke", "stroke-width",
        "stroke-opacity", "fill", "fill-opacity",
    ]
    /// Keys whose value, when it is nothing but http(s) URLs, becomes photo links (the KML
    /// `gx_media_links` convention plus common hand-written names). Read in sorted order.
    private static let photoKeys = ["gx_media_links", "image", "images", "photo", "photos"]

    private(set) var name: String?
    private(set) var descriptionHTML: String?
    private(set) var snippet: String?
    private(set) var address: String?
    private(set) var phoneNumber: String?
    private(set) var photoLinks: [String] = []
    private(set) var data: [KMLDataItem] = []
    private(set) var style: GeoJSONStyleKey?

    init(_ properties: [String: Any]) {
        var consumed: Set = ["description"]
        func take(_ key: String) -> String? {
            guard let value = Self.text(properties[key]) else { return nil }
            consumed.insert(key)
            return value
        }
        name = take("name") ?? take("title")
        descriptionHTML = Self.text(properties["description"]).map(Self.html)
        snippet = take("snippet")
        address = take("address")
        phoneNumber = take("phoneNumber") ?? take("phone")
        for key in Self.photoKeys {
            guard let links = Self.remoteLinks(properties[key]) else { continue }
            photoLinks += links
            consumed.insert(key)
        }
        style = Self.style(properties)
        if style?.iconHref != nil {
            consumed.insert("icon")
        }
        data = properties.keys.sorted().compactMap { key in
            guard !consumed.contains(key), !Self.styleKeys.contains(key),
                  let value = Self.text(properties[key]) else { return nil }
            return KMLDataItem(name: key, value: value)
        }
    }

    static func nonEmpty(_ string: String) -> String? {
        string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : string
    }

    /// Feature `id`: a string or a number.
    static func identifier(_ raw: Any?) -> String? {
        text(raw)
    }

    /// Strings as-is, numbers and booleans formatted, nested values JSON-encoded, null/empty dropped.
    static func text(_ raw: Any?) -> String? {
        switch raw {
        case let string as String:
            nonEmpty(string)
        case let number as NSNumber:
            format(number)
        case let list as [Any]:
            json(list)
        case let object as [String: Any]:
            json(object)
        default:
            nil
        }
    }

    private static func format(_ number: NSNumber) -> String? {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "true" : "false"
        }
        guard CFNumberIsFloatType(number) else { return number.stringValue }
        let value = number.doubleValue
        guard value.isFinite else { return nil }
        return value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : "\(value)"
    }

    private static func json(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value,
                                                     options: [.sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(bytes: data, encoding: .utf8)
    }

    /// Text holding a real HTML tag (a known element such as `<b>`, `</p>`, `<br/>`,
    /// `<img src=…>`, or an `<!--` comment) counts as HTML.
    /// Any other `<word>` is plain prose and must survive as text.
    private static let htmlTag = try? NSRegularExpression(
        pattern: "<!--|</?(?:a|abbr|b|big|blockquote|br|caption|center|cite|code|dd|del|div|dl|dt|em|font"
            + "|h[1-6]|hr|i|iframe|img|ins|li|mark|ol|p|pre|q|s|small|span|strike|strong|sub|sup|table"
            + "|tbody|td|tfoot|th|thead|tr|tt|u|ul)(?=[\\s/>])",
        options: .caseInsensitive
    )

    /// Plain text is escaped so `&` and `<` show literally; text that holds real HTML is kept.
    static func html(_ text: String) -> String {
        let hasTag = htmlTag?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        guard !hasTag else { return text }
        return text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// A string of whitespace-separated URLs, or an array of such strings, as photo links;
    /// nil unless every token is an http(s) URL (a lone file name cannot be resolved).
    private static func remoteLinks(_ raw: Any?) -> [String]? {
        let parts: [String]
        switch raw {
        case let string as String:
            parts = [string]
        case let list as [Any]:
            parts = list.compactMap { $0 as? String }
            guard parts.count == list.count else { return nil }
        default:
            return nil
        }
        let links = parts.flatMap { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
        guard !links.isEmpty, links.allSatisfy(isRemoteURL) else { return nil }
        return links
    }

    private static func isRemoteURL(_ string: String) -> Bool {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty
        else { return false }
        return true
    }

    // MARK: simplestyle

    private static func style(_ properties: [String: Any]) -> GeoJSONStyleKey? {
        var key = GeoJSONStyleKey()
        key.iconHref = (properties["icon"] as? String).flatMap { isRemoteURL($0) ? $0 : nil }
        key.iconColor = color(properties["marker-color"], opacity: 1)
        key.iconScale = scale(properties["marker-size"])
        key.lineColor = color(properties["stroke"], opacity: opacity(properties["stroke-opacity"], default: 1))
        let width = (properties["stroke-width"] as? NSNumber)?.doubleValue
        if key.lineColor != nil, let width, width.isFinite, width > 0 {
            key.lineWidth = width
        }
        key.polyColor = color(properties["fill"], opacity: opacity(properties["fill-opacity"], default: 0.6))
        return key == GeoJSONStyleKey() ? nil : key
    }

    /// simplestyle `marker-size`: `small` and `large` scale the icon; `medium` is the default.
    private static func scale(_ raw: Any?) -> Double? {
        switch (raw as? String)?.lowercased() {
        case "small": 0.75
        case "large": 1.5
        default: nil
        }
    }

    private static func opacity(_ raw: Any?, default fallback: Double) -> Double {
        guard let value = (raw as? NSNumber)?.doubleValue, value.isFinite else { return fallback }
        return min(max(value, 0), 1)
    }

    /// `#rgb` / `#rrggbb` to KML `aabbggrr`; anything else is nil.
    private static func color(_ raw: Any?, opacity: Double) -> String? {
        guard var hex = (raw as? String)?.trimmingCharacters(in: .whitespaces).lowercased(),
              hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        if hex.count == 3 {
            hex = hex.map { "\($0)\($0)" }.joined()
        }
        guard hex.count == 6, hex.allSatisfy(\.isHexDigit), hex.utf8.allSatisfy({ $0 < 0x80 }) else { return nil }
        let rr = hex.prefix(2), gg = hex.dropFirst(2).prefix(2), bb = hex.suffix(2)
        let alpha = String(format: "%02x", Int((opacity * 255).rounded()))
        return alpha + bb + gg + rr
    }
}
