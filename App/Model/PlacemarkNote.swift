import Foundation

/// A personal note on one placemark, stored in the entry's synced `metadata.json` under the
/// placemark's `stableKey`.
///
/// An empty `text` is a tombstone: it records that the note was deleted at `modifiedAt`, so a
/// deletion on one device survives an iCloud conflict merge instead of being resurrected by an
/// older copy.
struct PlacemarkNote: Codable, Equatable {
    var text: String
    var modifiedAt: Date
    /// The placemark's name when the note was last saved, so an orphaned note (its placemark
    /// gone after the file changed) can still be identified.
    var placemarkName: String?

    /// Whether this note records a deletion rather than live text.
    var isTombstone: Bool {
        text.isEmpty
    }

    /// The note that wins a merge: the later `modifiedAt`, ties broken by the lexicographically
    /// greater text, which keeps merging commutative and idempotent.
    static func winner(_ lhs: PlacemarkNote, _ rhs: PlacemarkNote) -> PlacemarkNote {
        if lhs.modifiedAt != rhs.modifiedAt {
            return lhs.modifiedAt > rhs.modifiedAt ? lhs : rhs
        }
        if lhs.text != rhs.text {
            return lhs.text > rhs.text ? lhs : rhs
        }
        return (lhs.placemarkName ?? "") >= (rhs.placemarkName ?? "") ? lhs : rhs
    }
}
