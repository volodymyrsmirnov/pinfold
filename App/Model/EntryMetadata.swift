import Foundation

/// The synced, on-disk sidecar for one catalogue entry, written as `metadata.json`
/// inside the entry's folder in the iCloud container.
///
/// This is the source of truth for an entry's *non-derivable* catalogue state
/// (display name, trash status) plus a cached copy of the cheap-but-not-free
/// derivable fields (`pointCount`, `contentSHA256`) so the reconciler can rebuild
/// the local SwiftData index without re-parsing every file on every launch.
struct EntryMetadata: Codable, Equatable, Sendable {
    var id: UUID
    var displayName: String
    var sourceFilename: String
    var importDate: Date
    var pointCount: Int
    var contentSHA256: String
    var trashedAt: Date?
    /// Stable keys (see `KMLPlacemark.stableKey`) of placemarks marked favorite.
    var favoriteKeys: Set<String> = []
    /// Stable keys of placemarks marked visited/seen.
    var visitedKeys: Set<String> = []

    init(
        id: UUID, displayName: String, sourceFilename: String, importDate: Date,
        pointCount: Int, contentSHA256: String, trashedAt: Date?,
        favoriteKeys: Set<String> = [], visitedKeys: Set<String> = []
    ) {
        self.id = id
        self.displayName = displayName
        self.sourceFilename = sourceFilename
        self.importDate = importDate
        self.pointCount = pointCount
        self.contentSHA256 = contentSHA256
        self.trashedAt = trashedAt
        self.favoriteKeys = favoriteKeys
        self.visitedKeys = visitedKeys
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, sourceFilename, importDate, pointCount
        case contentSHA256, trashedAt, favoriteKeys, visitedKeys
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        sourceFilename = try c.decode(String.self, forKey: .sourceFilename)
        importDate = try c.decode(Date.self, forKey: .importDate)
        pointCount = try c.decode(Int.self, forKey: .pointCount)
        contentSHA256 = try c.decode(String.self, forKey: .contentSHA256)
        trashedAt = try c.decodeIfPresent(Date.self, forKey: .trashedAt)
        favoriteKeys = Set(try c.decodeIfPresent([String].self, forKey: .favoriteKeys) ?? [])
        visitedKeys = Set(try c.decodeIfPresent([String].self, forKey: .visitedKeys) ?? [])
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(sourceFilename, forKey: .sourceFilename)
        try c.encode(importDate, forKey: .importDate)
        try c.encode(pointCount, forKey: .pointCount)
        try c.encode(contentSHA256, forKey: .contentSHA256)
        try c.encodeIfPresent(trashedAt, forKey: .trashedAt)
        // Encode sets as sorted arrays so the JSON is stable/diff-friendly (a Set's
        // array order is otherwise nondeterministic, causing spurious sync churn).
        try c.encode(favoriteKeys.sorted(), forKey: .favoriteKeys)
        try c.encode(visitedKeys.sorted(), forKey: .visitedKeys)
    }

    /// Encodes to pretty-printed, key-sorted JSON for stable, diff-friendly files.
    ///
    /// Dates use Codable's default strategy (a `Double` time interval) rather than
    /// ISO-8601 strings: the default round-trips with full precision, which the
    /// reconciler relies on when comparing `trashedAt` to detect real changes. An
    /// ISO-8601 string would drop sub-second precision and make every reconcile pass
    /// see a spurious change.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(self)
    }

    /// Decodes from the JSON produced by `encoded()`.
    static func decoded(from data: Data) throws -> EntryMetadata {
        try JSONDecoder().decode(EntryMetadata.self, from: data)
    }
}
