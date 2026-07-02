import Foundation
@testable import Pinfold
import Testing

/// Tests for `MapCameraStore` — the per-file remembered map camera (center/zoom/heading/
/// pitch), keyed by entry `storageFolderName`. Deliberately OUTSIDE the resume snapshot and
/// not gated by the restore toggle: it persists across sessions like the basemap style.
struct MapCameraStoreTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "MapCameraStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private let sample = MapCameraState(
        latitude: 48.85, longitude: 2.35, distance: 1200, heading: 90, pitch: 0
    )

    @Test func missingFolder_returnsNil() {
        #expect(MapCameraStore(defaults: makeDefaults()).camera(forFolderName: "nope") == nil)
    }

    @Test func camera_roundTripsPerFolder() {
        let defaults = makeDefaults()
        let store = MapCameraStore(defaults: defaults)
        store.setCamera(sample, forFolderName: "folder-a")

        // A fresh store on the same defaults sees it (persistence, not in-memory cache).
        #expect(MapCameraStore(defaults: defaults).camera(forFolderName: "folder-a") == sample)
        #expect(MapCameraStore(defaults: defaults).camera(forFolderName: "folder-b") == nil)
    }

    @Test func setCamera_overwrites() {
        let store = MapCameraStore(defaults: makeDefaults())
        store.setCamera(sample, forFolderName: "folder-a")
        let moved = MapCameraState(latitude: 1, longitude: 2, distance: 3, heading: 4, pitch: 5)
        store.setCamera(moved, forFolderName: "folder-a")
        #expect(store.camera(forFolderName: "folder-a") == moved)
    }

    @Test func corruptBlob_readsAsEmpty() {
        let defaults = makeDefaults()
        defaults.set(Data("garbage".utf8), forKey: "mapCameraStates")
        let store = MapCameraStore(defaults: defaults)
        #expect(store.camera(forFolderName: "folder-a") == nil)
        // And writing through the corrupt blob works (it is simply replaced).
        store.setCamera(sample, forFolderName: "folder-a")
        #expect(store.camera(forFolderName: "folder-a") == sample)
    }

    @Test func prune_belowCap_keepsStaleKeys() {
        let store = MapCameraStore(defaults: makeDefaults())
        store.setCamera(sample, forFolderName: "gone")
        store.pruneIfNeeded(keeping: ["still-here"], cap: 100)
        // Below the cap, stale entries are harmless bytes and are kept.
        #expect(store.camera(forFolderName: "gone") == sample)
    }

    @Test func prune_exactlyAtCap_keepsStaleKeys() {
        let store = MapCameraStore(defaults: makeDefaults())
        for index in 0 ..< 3 {
            store.setCamera(sample, forFolderName: "folder-\(index)")
        }
        // Exactly at the cap the dictionary has not yet OUTGROWN it — nothing is pruned.
        store.pruneIfNeeded(keeping: [], cap: 3)
        #expect(store.camera(forFolderName: "folder-0") == sample)
        #expect(store.camera(forFolderName: "folder-2") == sample)
    }

    @Test func prune_aboveCap_dropsOnlyAbsentKeys() {
        let store = MapCameraStore(defaults: makeDefaults())
        for index in 0 ..< 5 {
            store.setCamera(sample, forFolderName: "folder-\(index)")
        }
        store.pruneIfNeeded(keeping: ["folder-0", "folder-1"], cap: 3)
        #expect(store.camera(forFolderName: "folder-0") == sample)
        #expect(store.camera(forFolderName: "folder-1") == sample)
        #expect(store.camera(forFolderName: "folder-4") == nil)
    }
}
