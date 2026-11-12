/// Models both <Document> and <Folder> uniformly: a named, recursive container.
public struct KMLContainer: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String?
    public let children: [KMLContainer]
    public let placemarks: [KMLPlacemark]
    /// The container's own `<description>` HTML, if any.
    public let descriptionHTML: String?

    public init(id: String, name: String?, children: [KMLContainer], placemarks: [KMLPlacemark],
                descriptionHTML: String? = nil)
    // SwiftFormat puts the brace of a wrapped multi-line signature on its own line.
    // swiftlint:disable:next opening_brace
    {
        self.id = id
        self.descriptionHTML = descriptionHTML
        self.name = name
        self.children = children
        self.placemarks = placemarks
    }

    /// All placemarks in this container and its descendants, in document order.
    public var allPlacemarks: [KMLPlacemark] {
        var result: [KMLPlacemark] = []
        result.reserveCapacity(placemarkCount)
        appendPlacemarks(to: &result)
        return result
    }

    private func appendPlacemarks(to result: inout [KMLPlacemark]) {
        result.append(contentsOf: placemarks)
        for child in children {
            child.appendPlacemarks(to: &result)
        }
    }

    /// The first placemark anywhere in this container subtree whose `stableKey` equals
    /// `key`, in document order, or `nil` if none matches.
    ///
    /// Used to resolve a deep link (a Places search hit, a favorite, or a Spotlight result)
    /// to the placemark it points at. A repeated placemark shares a `stableKey`; the first
    /// occurrence is returned, matching how the search index and outline already collapse
    /// duplicates. Document order means this container's own placemarks are checked before
    /// its children's, consistent with `allPlacemarks`.
    public func firstPlacemark(withStableKey key: String) -> KMLPlacemark? {
        for placemark in placemarks where placemark.stableKey == key {
            return placemark
        }
        for child in children {
            if let match = child.firstPlacemark(withStableKey: key) {
                return match
            }
        }
        return nil
    }

    /// Total placemarks in this container and its descendants, computed by recursive
    /// summation without materializing the `allPlacemarks` arrays.
    public var placemarkCount: Int {
        placemarks.count + children.reduce(0) { $0 + $1.placemarkCount }
    }

    /// Placemarks with an explicit `<Point>` (`hasPoint`) in this container and its
    /// descendants, computed without materializing arrays.
    public var pointCount: Int {
        placemarks.reduce(0) { $0 + ($1.hasPoint ? 1 : 0) }
            + children.reduce(0) { $0 + $1.pointCount }
    }
}
