import Foundation

/// `<NetworkLink>` capture: its `<name>` and the `<href>` of its `<Link>` (or the legacy
/// `<Url>`). Only the href directly inside those wrappers counts, so icon and overlay hrefs
/// are never mistaken for links. Also the file-level `<NetworkLinkControl>` hints.
extension KMLParserDelegate {
    /// Handles the closing of a link `<href>` and of the `<NetworkLink>` itself. Returns true
    /// when the element was consumed. Call after the element stack was popped.
    func endNetworkLinkElement(_ local: String, trimmed: String) -> Bool {
        switch local {
        case "href":
            guard isNetworkLinkHref else { return false }
            if networkLinkHref == nil, !trimmed.isEmpty {
                networkLinkHref = trimmed
            }
            return true
        case "NetworkLink":
            if let href = networkLinkHref {
                networkLinks.append(KMLNetworkLink(name: networkLinkName, href: href,
                                                   refreshMode: networkLinkRefreshMode,
                                                   refreshInterval: networkLinkRefreshInterval))
            }
            networkLinkName = nil
            networkLinkHref = nil
            networkLinkRefreshMode = nil
            networkLinkRefreshInterval = nil
            return true
        case "refreshMode", "refreshInterval":
            guard isInNetworkLinkWrapper else { return false }
            if local == "refreshMode" {
                networkLinkRefreshMode = KMLRefreshMode(rawValue: trimmed)
            } else {
                networkLinkRefreshInterval = Double(trimmed)
            }
            return true
        case "minRefreshPeriod", "expires":
            guard elementStack.last == "NetworkLinkControl" else { return false }
            if local == "minRefreshPeriod" {
                controlMinRefreshPeriod = Double(trimmed)
            } else {
                controlExpires = Self.parseISO8601(trimmed)
            }
            return true
        default:
            return false
        }
    }

    /// True when the just-closed `<href>` sits in `NetworkLink > Link` or `NetworkLink > Url`
    /// (the stack already holds only the ancestors).
    private var isNetworkLinkHref: Bool {
        isInNetworkLinkWrapper
    }

    /// True when the just-closed element sits directly in a `NetworkLink`'s `Link`/`Url`.
    private var isInNetworkLinkWrapper: Bool {
        guard let wrapper = elementStack.last, wrapper == "Link" || wrapper == "Url" else { return false }
        return elementStack.dropLast().last == "NetworkLink"
    }

    /// Start-element hook (stack already holds `local`). Marks `<NetworkLinkControl>` and
    /// swallows its `<Update>` subtree so nothing inside it is captured. Returns true when
    /// the element was consumed.
    func startNetworkLinkControlElement(_ local: String, parent: String?) -> Bool {
        if updateDepth > 0 {
            updateDepth += 1
            wantsText = false
            return true
        }
        if local == "NetworkLinkControl" {
            hasNetworkLinkControl = true
        } else if local == "Update", parent == "NetworkLinkControl" {
            updateDepth = 1
            wantsText = false
            return true
        }
        return false
    }

    private static func parseISO8601(_ string: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: string) {
            return date
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string)
    }
}
