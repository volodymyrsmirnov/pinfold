import PinfoldCore

extension KMLContainer {
    /// The descendant at `path`, a `/`-separated list of child indices as used for folder ids
    /// by `PlacemarkOutline` (`""` is this container, `"0"` its first child, `"0/1"` that
    /// child's second child). `nil` when any component is not a valid index.
    func container(atPath path: String) -> KMLContainer? {
        guard !path.isEmpty else { return self }
        var current = self
        for part in path.split(separator: "/", omittingEmptySubsequences: false) {
            guard let index = Int(part), current.children.indices.contains(index) else { return nil }
            current = current.children[index]
        }
        return current
    }
}
