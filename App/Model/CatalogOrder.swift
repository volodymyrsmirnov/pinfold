import Foundation

/// The order of the catalogue's active list: newest import first.
///
/// Presentation-level only: `CatalogScanner` already produces the on-disk folders newest-first,
/// and this pins that order (with a deterministic tie-break) so equal import dates never shuffle
/// between reloads. Trash keeps its own trashed-date ordering.
enum CatalogOrder {
    /// `entries` newest import first; equal dates fall back to the display name
    /// (case-insensitive), then the id, so the result never depends on the input order.
    static func newestFirst(_ entries: [CatalogEntry]) -> [CatalogEntry] {
        entries.sorted { lhs, rhs in
            if lhs.importDate != rhs.importDate {
                return lhs.importDate > rhs.importDate
            }
            let nameOrder = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            // UUID is Comparable; byte order matches comparing the uppercase-hex strings.
            return lhs.id < rhs.id
        }
    }
}
