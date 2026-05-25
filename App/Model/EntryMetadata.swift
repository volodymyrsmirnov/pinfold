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
