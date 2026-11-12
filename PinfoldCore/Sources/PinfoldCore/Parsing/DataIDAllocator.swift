/// Hands out ids unique within a placemark: `name`, then `name#2`, `name#3`, ... for repeats.
/// O(1) per item: ids are never freed, so every suffix up to the last one issued for a name is
/// known to be taken.
struct DataIDAllocator {
    private var used: Set<String> = []
    private var lastSuffix: [String: Int] = [:]

    mutating func next(for name: String) -> String {
        var id = name
        if used.contains(id) {
            var n = lastSuffix[name] ?? 1
            repeat {
                n += 1
                id = "\(name)#\(n)"
            } while used.contains(id)
            lastSuffix[name] = n
        }
        used.insert(id)
        return id
    }
}
