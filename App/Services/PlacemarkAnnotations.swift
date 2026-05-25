import Foundation
import Observation
import PinfoldCore

/// The favorite/visited state for the *currently open* KML file.
///
/// Owned by `KMLDetailView` for one entry and injected into the environment so every
/// descendant (rows, detail view, map, preview card) reads the same instance. State is
/// keyed by `KMLPlacemark.stableKey` and persisted to the entry's `metadata.json`.
///
/// Toggling mutates the in-memory set (instant UI via `@Observable`) and synchronously
/// writes through to the sidecar via `StorageLocations.updateMetadata` — it never reloads
/// the catalogue or re-parses the open document. The store is `@MainActor`-bound, so all
/// toggles and writes are serialized; the sidecar is sub-KB JSON, making the synchronous
/// write-through negligible in wall-clock time.
@MainActor @Observable final class PlacemarkAnnotations {
    private(set) var favoriteKeys: Set<String>
    private(set) var visitedKeys: Set<String>

    @ObservationIgnored private let storage: StorageLocations
    @ObservationIgnored private let folderName: String
    @ObservationIgnored private var canPersist = true

    init(entry: CatalogEntry, storage: StorageLocations) {
        self.storage = storage
        self.folderName = entry.storageFolderName
        do {
            let meta = try storage.readMetadata(forFolderNamed: entry.storageFolderName)
            self.favoriteKeys = meta?.favoriteKeys ?? []
            self.visitedKeys = meta?.visitedKeys ?? []
        } catch {
            // Sidecar exists but failed to decode (corrupt/truncated). Start empty but
            // refuse to persist, so a toggle never overwrites recoverable data.
            self.favoriteKeys = []
            self.visitedKeys = []
            self.canPersist = false
        }
    }

    func isFavorite(_ placemark: KMLPlacemark) -> Bool { favoriteKeys.contains(placemark.stableKey) }
    func isVisited(_ placemark: KMLPlacemark) -> Bool { visitedKeys.contains(placemark.stableKey) }

    /// A VoiceOver-friendly description combining the placemark name with its
    /// favorite/visited state, e.g. "Mount Everest, Favorite, Visited".
    func accessibilityDescription(for placemark: KMLPlacemark) -> String {
        var parts = [placemark.name ?? "Untitled"]
        if isFavorite(placemark) { parts.append("Favorite") }
        if isVisited(placemark) { parts.append("Visited") }
        return parts.joined(separator: ", ")
    }

    func toggleFavorite(_ placemark: KMLPlacemark) {
        toggle(&favoriteKeys, key: placemark.stableKey)
        persist()
    }

    func toggleVisited(_ placemark: KMLPlacemark) {
        toggle(&visitedKeys, key: placemark.stableKey)
        persist()
    }

    private func toggle(_ set: inout Set<String>, key: String) {
        if set.contains(key) { set.remove(key) } else { set.insert(key) }
    }

    private func persist() {
        guard canPersist else { return }
        // Write failure is intentionally swallowed: in-memory state stays updated for this
        // session; a failed write (disk full / iCloud unavailable) will appear undone on next
        // launch. Fine for a lightweight annotation store.
        try? storage.updateMetadata(forFolderNamed: folderName) { meta in
            meta.favoriteKeys = favoriteKeys
            meta.visitedKeys = visitedKeys
        }
    }
}
