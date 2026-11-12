/// `<NetworkLink>` capture: its `<name>` and the `<href>` of its `<Link>` (or the legacy
/// `<Url>`). Only the href directly inside those wrappers counts, so icon and overlay hrefs
/// are never mistaken for links.
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
                networkLinks.append(KMLNetworkLink(name: networkLinkName, href: href))
            }
            networkLinkName = nil
            networkLinkHref = nil
            return true
        default:
            return false
        }
    }

    /// True when the just-closed `<href>` sits in `NetworkLink > Link` or `NetworkLink > Url`
    /// (the stack already holds only the ancestors).
    private var isNetworkLinkHref: Bool {
        guard let wrapper = elementStack.last, wrapper == "Link" || wrapper == "Url" else { return false }
        return elementStack.dropLast().last == "NetworkLink"
    }
}
