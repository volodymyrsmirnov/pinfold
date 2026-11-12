/// The style fields of one `<Style>`, without an id. Hashable so identical inline styles
/// can share one synthesized id.
struct StyleFields: Hashable {
    var iconHref: String?
    var iconColor: String?
    var iconScale: Double?
    var lineColor: String?
    var lineWidth: Double?
    var polyColor: String?
    var polyFill: Bool?

    init(_ builder: KMLParserDelegate.StyleBuilder) {
        iconHref = builder.iconHref
        iconColor = builder.iconColor
        iconScale = builder.iconScale
        lineColor = builder.lineColor
        lineWidth = builder.lineWidth
        polyColor = builder.polyColor
        polyFill = builder.polyFill
    }

    init(_ style: KMLStyle) {
        iconHref = style.iconHref
        iconColor = style.iconColor
        iconScale = style.iconScale
        lineColor = style.lineColor
        lineWidth = style.lineWidth
        polyColor = style.polyColor
        polyFill = style.polyFill
    }

    /// True when no field is set (a `<Style>` carrying only Balloon/List/Label styling).
    var isEmpty: Bool {
        self == StyleFields(KMLParserDelegate.StyleBuilder(id: ""))
    }

    /// Field-wise merge: `self` wins, missing fields fall back to `base`.
    func merged(over base: StyleFields?) -> StyleFields {
        guard let base else { return self }
        var result = self
        result.iconHref = iconHref ?? base.iconHref
        result.iconColor = iconColor ?? base.iconColor
        result.iconScale = iconScale ?? base.iconScale
        result.lineColor = lineColor ?? base.lineColor
        result.lineWidth = lineWidth ?? base.lineWidth
        result.polyColor = polyColor ?? base.polyColor
        result.polyFill = polyFill ?? base.polyFill
        return result
    }
}

/// An inline style waiting for `makeDocument()`, which knows every shared style.
struct PendingInlineStyle {
    let placemarkID: String
    let fields: StyleFields
    let sharedStyleUrl: String?
}

extension KMLParserDelegate {
    /// Registers one synthesized style per distinct merged inline style in `styles` and
    /// returns the placemark id -> rewritten `styleUrl` table. Merging happens here, not at
    /// parse time, because a shared style may be defined after the placemark that uses it.
    func resolveInlineStyles() -> [String: String] {
        var overrides: [String: String] = [:]
        var idsByFields: [StyleFields: String] = [:]
        var counter = 0
        for pending in pendingInlineStyles {
            let base = Self.resolve(pending.sharedStyleUrl, styles: styles, styleMaps: styleMaps)
            let fields = pending.fields.merged(over: base.map(StyleFields.init))
            let id: String
            if let known = idsByFields[fields] {
                id = known
            } else {
                // Skip ids the author already used, for either a style or a style map.
                var candidate: String
                repeat {
                    counter += 1
                    candidate = "_inline\(counter)"
                } while styles[candidate] != nil || styleMaps[candidate] != nil
                id = candidate
                styles[id] = KMLStyle(id: id, iconHref: fields.iconHref,
                                      iconColor: fields.iconColor, iconScale: fields.iconScale,
                                      lineColor: fields.lineColor, lineWidth: fields.lineWidth,
                                      polyColor: fields.polyColor, polyFill: fields.polyFill)
                idsByFields[fields] = id
            }
            overrides[pending.placemarkID] = "#\(id)"
        }
        return overrides
    }

    /// Follows one StyleMap hop, like `KMLDocument.resolvedStyle(forStyleUrl:)`.
    private static func resolve(_ url: String?, styles: [String: KMLStyle],
                                styleMaps: [String: String]) -> KMLStyle?
    {
        func key(_ raw: String?) -> String? {
            guard let raw, !raw.isEmpty else { return nil }
            return raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        }
        guard let id = key(url) else { return nil }
        if let direct = styles[id] {
            return direct
        }
        if let mapped = key(styleMaps[id]) {
            return styles[mapped]
        }
        return nil
    }
}
