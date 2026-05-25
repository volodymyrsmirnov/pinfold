import SwiftUI

@main
struct PinfoldApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

// MARK: - RootView

/// Bootstraps the app's services once and provides the root `NavigationStack`.
///
/// There is no SwiftData container: the catalogue lives in the folders on disk and is held
/// in memory by `Catalog`, which is sourced from whichever root is active (local Application
/// Support, or the iCloud container's `Documents` when sync is on). `AppSettings` (sync
/// toggle + map prefs) is UserDefaults-backed.
private struct RootView: View {
    @State private var settings: AppSettings
    @State private var catalog: Catalog
    @State private var mapAppService: MapAppService
    @State private var resourceCache: ResourceCache
    @State private var watcher: CatalogWatcher?
    /// Whether the catalogue's current root is the iCloud (ubiquitous) container. Tracked so
    /// migrations pick the right file API (`setUbiquitous` vs `moveItem`).
    @State private var rootIsUbiquitous = false

    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Start on local storage (synchronously knowable). `bootstrap()` resolves the real
        // root — iCloud if sync is on and available — and switches to it.
        let cache = ResourceCache()
        _settings = State(initialValue: AppSettings())
        _resourceCache = State(initialValue: cache)
        _mapAppService = State(initialValue: MapAppService())
        _catalog = State(initialValue: Catalog(storage: .applicationSupport, cache: cache))
    }

    var body: some View {
        NavigationStack {
            HomeView()
        }
        .environment(catalog)
        .environment(settings)
        .environment(mapAppService)
        .environment(\.resourceCache, resourceCache)
        .environment(\.storageLocations, catalog.storage)
        .task { await bootstrap() }
        // Pick up files synced or shared while the app was already running.
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await drainInbox(); await catalog.reload() }
            }
        }
        // Apply the iCloud toggle live: switch the active root (migrating existing files)
        // and restart the watcher. No relaunch required.
        .onChange(of: settings.syncEnabled) { _, _ in
            Task { await applyStorage(migrate: true) }
        }
    }

    /// One-time startup: resolve the active root, drain the inbox, reload, start watching.
    private func bootstrap() async {
        await applyStorage(migrate: false)
        await drainInbox()
        await catalog.reload()
    }

    /// Resolves the active root from the current sync preference, points the catalogue at
    /// it, and (re)starts the watcher.
    ///
    /// - Parameter migrate: `true` for the toggle path (move existing files into the new
    ///   root, choosing the iCloud-aware file API); `false` for launch (the files are
    ///   already where the resolved root expects them).
    private func applyStorage(migrate: Bool) async {
        let (storage, ubiquitous) = await resolveStorage()
        if migrate {
            let from = catalog.storage.root
            let wasUbiquitous = rootIsUbiquitous
            try? await Task.detached {
                try StorageLocations.migrateEntryFolders(
                    from: from,
                    to: storage.root,
                    fromUbiquitous: wasUbiquitous,
                    toUbiquitous: ubiquitous
                )
            }.value
        }
        await catalog.setStorage(storage)
        rootIsUbiquitous = ubiquitous
        startWatcher(root: storage.root, ubiquitous: ubiquitous)
    }

    /// Returns the storage layout for the current preference, plus whether it is the iCloud
    /// (ubiquitous) container. Falls back to local storage when sync is off or iCloud is
    /// unavailable.
    private func resolveStorage() async -> (StorageLocations, Bool) {
        guard settings.syncEnabled else { return (.applicationSupport, false) }
        let documentsURL = await Task.detached { UbiquityContainer.documentsURL() }.value
        guard let documentsURL else { return (.applicationSupport, false) }
        return (.synced(root: documentsURL), true)
    }

    /// Starts a fresh watcher on `root`, replacing any previous one.
    private func startWatcher(root: URL, ubiquitous: Bool) {
        let watcher = CatalogWatcher { [catalog] in
            Task { await catalog.reload() }
        }
        watcher.start(root: root, ubiquitous: ubiquitous)
        self.watcher = watcher
    }

    /// Drains the share-extension inbox into the active root, if the App Group is available.
    private func drainInbox() async {
        guard let inboxURL = AppGroup.inboxURL else { return }
        let inbox = PendingImportInbox(
            inboxURL: inboxURL,
            catalog: catalog,
            storage: catalog.storage,
            cache: resourceCache
        )
        await inbox.drain()
    }
}
