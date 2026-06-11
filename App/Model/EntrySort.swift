import Foundation
import SwiftUI

/// How the catalogue's active list is ordered in the UI.
///
/// Sorting is **presentation-level only**: `CatalogScanner` always produces the on-disk
/// folders newest-first, and `EntrySort.apply(to:)` reorders that list in the view. Storage
/// order is never changed by the user's sort choice — a different device with a different
/// preference still reads the same files. Trash keeps its own trashed-date ordering and is
/// not affected by this enum.
enum EntrySort: String, CaseIterable, Identifiable {
    /// Newest import first — the default, matching the scanner's storage order.
    case dateDesc
    /// Display name, A→Z, case-insensitively.
    case nameAsc
    /// Most placemarks first.
    case pointCountDesc

    var id: String {
        rawValue
    }

    /// A localized label for the sort menu / picker.
    var label: LocalizedStringKey {
        switch self {
        case .dateDesc: "Date Added"
        case .nameAsc: "Name"
        case .pointCountDesc: "Most Points"
        }
    }

    /// Reorders `entries` for display. Every ordering uses the same deterministic tie-break —
    /// secondary by `displayName` (case-insensitive), then by `id` — so equal primary keys
    /// produce a stable, input-order-independent result (important for tests and for a steady
    /// list across reloads).
    func apply(to entries: [CatalogEntry]) -> [CatalogEntry] {
        entries.sorted { lhs, rhs in
            switch self {
            case .dateDesc:
                if lhs.importDate != rhs.importDate { return lhs.importDate > rhs.importDate }
            case .nameAsc:
                break // primary key is the tie-break itself (name); fall through.
            case .pointCountDesc:
                if lhs.pointCount != rhs.pointCount { return lhs.pointCount > rhs.pointCount }
            }
            // Deterministic tie-break shared by every case.
            let nameOrder = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            // UUID is Comparable; its byte-order comparison is order-equivalent to comparing
            // the uppercase-hex `uuidString`, so this avoids allocating two strings per tie-break
            // while keeping ordering identical.
            return lhs.id < rhs.id
        }
    }
}
