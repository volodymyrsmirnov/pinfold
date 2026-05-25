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
}
