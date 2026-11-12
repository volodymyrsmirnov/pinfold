public struct KMLDataItem: Equatable, Sendable, Identifiable {
    /// Unique within a placemark: `name`, with a `#2`, `#3` ... suffix for repeated names.
    public let id: String
    public let name: String
    public let value: String
    /// The `<displayName>` of a `<Data>` element, if any.
    public let displayName: String?

    public init(name: String, value: String, displayName: String? = nil, id: String? = nil) {
        self.id = id ?? name
        self.name = name
        self.value = value
        self.displayName = displayName
    }
}
