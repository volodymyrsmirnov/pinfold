import SwiftUI

// MARK: - ResourceCache environment key

/// Environment key for injecting a `ResourceCache` instance into the view hierarchy.
///
/// `ResourceCache` is not `@Observable` (it is a value-less, immutable service) so it
/// cannot use the `@Environment(Type.self)` form. Views access it via:
/// ```swift
/// @Environment(\.resourceCache) private var resourceCache
/// ```
private struct ResourceCacheKey: EnvironmentKey {
    static let defaultValue = ResourceCache()
}

extension EnvironmentValues {
    /// The shared `ResourceCache` for the current scene.
    var resourceCache: ResourceCache {
        get { self[ResourceCacheKey.self] }
        set { self[ResourceCacheKey.self] = newValue }
    }
}

extension View {
    /// Injects a `ResourceCache` into the environment.
    func resourceCache(_ cache: ResourceCache) -> some View {
        environment(\.resourceCache, cache)
    }
}

// MARK: - StorageLocations environment key

/// Environment key for the *active* `StorageLocations`. This is local Application Support
/// by default, but is swapped for the iCloud-container root at launch when iCloud sync is
/// enabled (see `RootView.configureStorage`). Views must resolve original-file and
/// resource paths through this — never `StorageLocations.applicationSupport` directly —
/// or they will look in the wrong root when sync is on and fail to find files.
private struct StorageLocationsKey: EnvironmentKey {
    static let defaultValue = StorageLocations.applicationSupport
}

extension EnvironmentValues {
    /// The active `StorageLocations` for the current scene.
    var storageLocations: StorageLocations {
        get { self[StorageLocationsKey.self] }
        set { self[StorageLocationsKey.self] = newValue }
    }
}

extension View {
    /// Injects the active `StorageLocations` into the environment.
    func storageLocations(_ storage: StorageLocations) -> some View {
        environment(\.storageLocations, storage)
    }
}
