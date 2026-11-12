import Foundation

/// Style identity used to deduplicate synthesized styles (KML colours are `aabbggrr`).
struct GeoJSONStyleKey: Hashable {
    var iconColor: String?
    var lineColor: String?
    var lineWidth: Double?
    var polyColor: String?
}

/// Feature `properties` mapped to placemark fields: `name` (else `title`), `description`,
/// simplestyle keys (-> style) and everything else as sorted extended data.
struct GeoJSONProperties {
    private static let styleKeys: Set<String> = [
        "marker-color", "marker-size", "marker-symbol", "stroke", "stroke-width",
        "stroke-opacity", "fill", "fill-opacity",
    ]

    private(set) var name: String?
    private(set) var descriptionHTML: String?
    private(set) var data: [KMLDataItem] = []
    private(set) var style: GeoJSONStyleKey?

    init(_ properties: [String: Any]) {
        var consumed: Set = ["description"]
        if let direct = Self.text(properties["name"]) {
            name = direct
            consumed.insert("name")
        } else if let title = Self.text(properties["title"]) {
            name = title
            consumed.insert("title")
        }
        descriptionHTML = Self.text(properties["description"]).map(Self.html)
        data = properties.keys.sorted().compactMap { key in
            guard !consumed.contains(key), !Self.styleKeys.contains(key),
                  let value = Self.text(properties[key]) else { return nil }
            return KMLDataItem(name: key, value: value)
        }
        style = Self.style(properties)
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

    /// Plain text is escaped so `&` and `<` show literally; text that already holds tags is kept.
    private static func html(_ text: String) -> String {
        let hasTag = text.range(of: "<[A-Za-z/!]", options: .regularExpression) != nil
        guard !hasTag else { return text }
        return text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: simplestyle

    private static func style(_ properties: [String: Any]) -> GeoJSONStyleKey? {
        var key = GeoJSONStyleKey()
        key.iconColor = color(properties["marker-color"], opacity: 1)
        key.lineColor = color(properties["stroke"], opacity: opacity(properties["stroke-opacity"], default: 1))
        let width = (properties["stroke-width"] as? NSNumber)?.doubleValue
        if key.lineColor != nil, let width, width.isFinite, width > 0 {
            key.lineWidth = width
        }
        key.polyColor = color(properties["fill"], opacity: opacity(properties["fill-opacity"], default: 0.6))
        return key == GeoJSONStyleKey() ? nil : key
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
