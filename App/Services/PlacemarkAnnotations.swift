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
/// the catalogue or re-parses the open document. The sidecar is sub-KB JSON, so the
/// main-actor write is cheap and serializes concurrent toggles for free.
@MainActor @Observable final class PlacemarkAnnotations {
    private(set) var favoriteKeys: Set<String>
    private(set) var visitedKeys: Set<String>

    @ObservationIgnored private let storage: StorageLocations
    @ObservationIgnored private let folderName: String

    init(entry: CatalogEntry, storage: StorageLocations) {
        self.storage = storage
        self.folderName = entry.storageFolderName
        let meta = try? storage.readMetadata(forFolderNamed: entry.storageFolderName)
        self.favoriteKeys = meta?.favoriteKeys ?? []
        self.visitedKeys = meta?.visitedKeys ?? []
    }

    func isFavorite(_ placemark: KMLPlacemark) -> Bool { favoriteKeys.contains(placemark.stableKey) }
    func isVisited(_ placemark: KMLPlacemark) -> Bool { visitedKeys.contains(placemark.stableKey) }

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
        try? storage.updateMetadata(forFolderNamed: folderName) { meta in
            meta.favoriteKeys = favoriteKeys
            meta.visitedKeys = visitedKeys
        }
    }
}
