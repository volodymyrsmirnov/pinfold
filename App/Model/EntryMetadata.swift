import Foundation

/// The synced, on-disk sidecar for one catalogue entry, written as `metadata.json`
/// inside the entry's folder in the iCloud container.
///
/// This is the source of truth for an entry's *non-derivable* catalogue state
/// (display name, trash status) plus a cached copy of the cheap-but-not-free
/// derivable fields (`pointCount`, `contentSHA256`) so the reconciler can rebuild
/// the local SwiftData index without re-parsing every file on every launch.
struct EntryMetadata: Codable, Equatable {
    /// Stable entry identity. For every entry created after the crash-safe-commit change this
    /// equals the folder-name UUID (`UUID(uuidString: storageFolderName)`): `commit` derives
    /// it from the folder name, and `CatalogScanner.rebuildFromBareOriginal` reuses the same
    /// UUID when backfilling. Keeping the two in lockstep prevents identity drift when an
    /// entry is rebuilt from a bare original on another device. Legacy sidecars may carry an
    /// unrelated UUID; nothing keys storage operations on `id` (those use `storageFolderName`).
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
    /// User-assigned labels on this entry (per-ENTRY, not per-placemark). Normalized by
    /// `Catalog.setTags` (trimmed, de-duplicated case-insensitively, sorted); stored as a
    /// plain array so the order is exactly the diff-stable sorted order written to disk.
    var tags: [String] = []

    init(
        id: UUID, displayName: String, sourceFilename: String, importDate: Date,
        pointCount: Int, contentSHA256: String, trashedAt: Date?,
        favoriteKeys: Set<String> = [], visitedKeys: Set<String> = [],
        tags: [String] = []
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
        self.tags = tags
    }

    // IMPORTANT: Codable is hand-written (not synthesised) so favoriteKeys/visitedKeys
    // can use decodeIfPresent for legacy files and encode as sorted arrays. When adding a
    // property, update CodingKeys, init(from:), encode(to:), AND the memberwise init.
    private enum CodingKeys: String, CodingKey {
        case id, displayName, sourceFilename, importDate, pointCount
        case contentSHA256, trashedAt, favoriteKeys, visitedKeys, tags
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
        favoriteKeys = try Set(c.decodeIfPresent([String].self, forKey: .favoriteKeys) ?? [])
        visitedKeys = try Set(c.decodeIfPresent([String].self, forKey: .visitedKeys) ?? [])
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
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
        // Tags are already kept sorted by `Catalog.setTags`, but sort again here so a
        // hand-built/legacy-merged value still serializes diff-stably.
        try c.encode(tags.sorted(), forKey: .tags)
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

    /// Resolves an iCloud edit conflict by merging this (the current, on-disk winner) with
    /// the loser `conflicts` versions, producing a single sidecar that loses no user intent.
    ///
    /// Merge rules:
    /// - `favoriteKeys` / `visitedKeys`: **union** across all versions. Marks made on
    ///   different devices are additive — neither device's stars/visited flags are dropped.
    /// - `tags`: **union** across all versions (case-sensitive set union, then re-sorted),
    ///   consistent with `favoriteKeys` — a tag added on one device is never lost by a
    ///   conflicting copy that never saw it.
    /// - Scalar identity/content fields (`id`, `displayName`, `sourceFilename`, `importDate`,
    ///   `pointCount`, `contentSHA256`): keep **current's** values. These describe the same
    ///   underlying file, so the winning version is authoritative; there is nothing to merge.
    /// - `trashedAt`: the **maximum** of all non-nil `trashedAt` values across current and
    ///   conflicts, or `nil` if every version is non-trashed. A trash performed on one device
    ///   therefore wins over an unaware copy (deletion is the user's most recent intent), and
    ///   when two devices both trashed, the later timestamp survives.
    func merging(conflicts: [EntryMetadata]) -> EntryMetadata {
        var merged = self
        var tagSet = Set(tags)
        for other in conflicts {
            merged.favoriteKeys.formUnion(other.favoriteKeys)
            merged.visitedKeys.formUnion(other.visitedKeys)
            tagSet.formUnion(other.tags)
        }
        merged.tags = tagSet.sorted()
        let trashStamps = ([self] + conflicts).compactMap(\.trashedAt)
        merged.trashedAt = trashStamps.max()
        return merged
    }
}
