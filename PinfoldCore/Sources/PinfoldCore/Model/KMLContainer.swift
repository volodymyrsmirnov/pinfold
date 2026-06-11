/// Models both <Document> and <Folder> uniformly: a named, recursive container.
public struct KMLContainer: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String?
    public let children: [KMLContainer]
    public let placemarks: [KMLPlacemark]

    public init(id: String, name: String?, children: [KMLContainer], placemarks: [KMLPlacemark]) {
        self.id = id
        self.name = name
        self.children = children
        self.placemarks = placemarks
    }

    /// All placemarks in this container and its descendants, in document order.
    public var allPlacemarks: [KMLPlacemark] {
        placemarks + children.flatMap(\.allPlacemarks)
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
