import Foundation

/// The synced, on-disk sidecar for one catalogue entry, written as `metadata.json`
/// inside the entry's folder in the iCloud container.
///
/// This is the source of truth for an entry's *non-derivable* catalogue state
/// (display name, trash status) plus a cached copy of the cheap-but-not-free
/// derivable fields (`pointCount`, `contentSHA256`) so the catalogue scanner can rebuild
/// the in-memory list without re-parsing every file on every launch.
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
    /// Labels written by Pinfold versions that had tagging (removed in 2.1). Nothing reads or
    /// edits them any more, but they are decoded, merged and re-encoded unchanged so a device
    /// still on an older version doesn't lose them when iCloud syncs this sidecar.
    var tags: [String] = []
    /// Personal notes keyed by `KMLPlacemark.stableKey`. An empty-text note is a tombstone.
    /// Notes are kept even when their key no longer resolves (see `PlacemarkNote`).
    var notes: [String: PlacemarkNote] = [:]
    /// Set when the list follows a URL and refreshes itself; `nil` for a normal list.
    var subscription: Subscription?

    init(
        id: UUID, displayName: String, sourceFilename: String, importDate: Date,
        pointCount: Int, contentSHA256: String, trashedAt: Date?,
        favoriteKeys: Set<String> = [], visitedKeys: Set<String> = [],
        tags: [String] = [], notes: [String: PlacemarkNote] = [:],
        subscription: Subscription? = nil
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
        self.notes = notes
        self.subscription = subscription
    }

    // IMPORTANT: Codable is hand-written (not synthesised) so favoriteKeys/visitedKeys
    // can use decodeIfPresent for legacy files and encode as sorted arrays. When adding a
    // property, update CodingKeys, init(from:), encode(to:), AND the memberwise init.
    private enum CodingKeys: String, CodingKey {
        case id, displayName, sourceFilename, importDate, pointCount
        case contentSHA256, trashedAt, favoriteKeys, visitedKeys, tags, notes, subscription
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
        notes = try c.decodeIfPresent([String: PlacemarkNote].self, forKey: .notes) ?? [:]
        subscription = try c.decodeIfPresent(Subscription.self, forKey: .subscription)
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
        // Legacy tags (written by versions that had tagging) are round-tripped untouched;
        // sorted so a merged value still serializes diff-stably.
        try c.encode(tags.sorted(), forKey: .tags)
        if !notes.isEmpty {
            try c.encode(notes, forKey: .notes)
        }
        try c.encodeIfPresent(subscription, forKey: .subscription)
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
    /// - `notes`: per key, the note with the newest `modifiedAt` wins (ties go to the
    ///   lexicographically greater text), so the merge is commutative and idempotent. A
    ///   tombstone (empty text) competes like any other note. Notes for keys that no longer
    ///   resolve to a placemark are kept.
    /// - Scalar identity/content fields (`id`, `displayName`, `sourceFilename`, `importDate`,
    ///   `pointCount`, `contentSHA256`): keep **current's** values. These describe the same
    ///   underlying file, so the winning version is authoritative; there is nothing to merge.
    /// - `subscription`: keeps **current's** value (the winning version is authoritative).
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
        for other in conflicts {
            for (key, note) in other.notes {
                merged.notes[key] = merged.notes[key].map { PlacemarkNote.winner($0, note) } ?? note
            }
        }
        let trashStamps = ([self] + conflicts).compactMap(\.trashedAt)
        merged.trashedAt = trashStamps.max()
        return merged
    }
}
