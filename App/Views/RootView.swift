import CoreSpotlight
import os
import SwiftUI

// MARK: - RootView

/// Bootstraps the app's services once and provides the root `NavigationSplitView`.
///
/// The sidebar hosts the catalogue (`HomeView`); the detail column hosts the selected
/// entry's `KMLDetailView` inside its own `NavigationStack` (so placemark/map pushes stay
/// in the detail column on a regular-width canvas). On compact width the split view
/// collapses to a single stack and selection drives a push, preserving the old phone flow.
///
/// There is no SwiftData container: the catalogue lives in the folders on disk and is held
/// in memory by `Catalog`, which is sourced from whichever root is active (local Application
/// Support, or the iCloud container's `Documents` when sync is on). `AppSettings` (sync
/// toggle + map prefs) is UserDefaults-backed.
struct RootView: View {
    /// Diagnostics for the storage-root migration (no app-wide logging facility exists yet).
    static let migrationLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Pinfold",
        category: "migration"
    )

    /// Diagnostics for deep-link routing (App Intents + Spotlight taps) that resolve to a
    /// missing/trashed entry — surfaced here rather than to the user (a no-op is fine).
    static let routingLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Pinfold",
        category: "spotlight"
    )

    @State var settings: AppSettings
    @State var catalog: Catalog
    @State var mapAppService: MapAppService
    @State var resourceCache: ResourceCache
    @State var watcher: CatalogWatcher?
    /// Deep-link sink for App Intents (and any future programmatic navigation). Published to
    /// `AppDependencies` at bootstrap so the out-of-tree `OpenEntryIntent` can drive selection.
    @State var router = NavigationRouter()
    /// Surfaces partial-migration failures to the Settings flow as an alert.
    @State var migrationAlert = MigrationAlertState()
    /// Surfaces import failures (parse or I/O) from every arrival path to `HomeView`.
    @State var importFailureLog: ImportFailureLog
    /// The single import queue shared by the file picker, "Open in" and both inboxes. Injected
    /// into the environment so `HomeView` reads progress and prompts from it.
    @State var importCoordinator: ImportCoordinator
    /// Whether the catalogue's current root is the iCloud (ubiquitous) container. Tracked so
    /// migrations pick the right file API (`setUbiquitous` vs `moveItem`).
    @State var rootIsUbiquitous = false
    /// Whether iCloud sync is doing what the user asked; shared through the environment.
    @State var syncStatus = SyncStatus()
    /// Serialises every storage application so a re-resolve cannot interleave with a toggle.
    @State var storageQueue = StorageApplyQueue()

    /// The sidebar selection, stored by **entry id** rather than by value. `CatalogEntry` is a
    /// value type rebuilt from disk on every `catalog.reload()`, so a stored value would go
    /// stale (and break `List` selection equality) after any reload, trash, or rename. Storing
    /// the stable `UUID` and resolving it against `catalog.entries` keeps the selection alive
    /// across reloads, and naturally clears it when the entry disappears (deleted) or is
    /// trashed (the sidebar only exposes active entries for selection).
    @State var selectedEntryID: CatalogEntry.ID?

    /// A one-shot deep-link target handed to the detail view when a selection is triggered by a
    /// catalogue-wide placemark hit (a "Places" search result, a favorite, or a Spotlight
    /// result). It carries the placemark's durable `stableKey` so `KMLDetailView` resolves it
    /// against the parsed document and pushes `PlacemarkDetailView` (the POI page).
    ///
    /// Consume-once flow: the source sets this AND `selectedEntryID` together when a hit is
    /// tapped; `activeRestore` wraps it into a `RestoreBundle` passed to
    /// `KMLDetailView(initialRestore:)`, which clears it via `onConsumeRestore`. A normal row
    /// tap only changes `selectedEntryID` (leaving this nil), so it does not push.
    @State var pendingPlacemarkKey: String?

    /// A one-shot session-restore payload built by `restoreSessionIfNeeded()` (Task 6) and
    /// handed to `KMLDetailView` when the restored entry's view is created. `entryFolderName`
    /// guards the hand-off: only the matching entry receives it (a user could out-race a slow
    /// parse by selecting another file). Deep links win: `activeRestore` prefers
    /// `pendingPlacemarkKey`, and every deep-link site clears this.
    @State var pendingRestore: RestoreBundle?

    /// Set when the app is (re)activated by a URL ("Open in Pinfold" / share-extension
    /// launch). An import doesn't drive a selection, so the selection-based restore guards
    /// can't see it — this flag keeps session restore from reopening the previous file on
    /// top of a fresh import.
    @State var suppressRestore = false

    /// A deep-link target (Spotlight tap or App Intent) that arrived before `bootstrap()`
    /// had loaded the catalogue, stashed for replay right after the first reload. Without
    /// this, a cold-launch tap resolves against an empty catalogue, gets dropped, and
    /// session restore then opens the PREVIOUS file instead of the tapped one.
    @State var pendingColdLaunchTarget: (folderName: String, placemarkKey: String?)?

    /// Whether `bootstrap()` has completed its first catalogue load. Gates the stash above:
    /// a post-bootstrap resolution miss is a genuinely missing entry, not a launch race.
    @State var didBootstrap = false
    /// Set while a failed migration flips `syncEnabled` back, so the change handler ignores it.
    @State var revertingSyncSetting = false

    @Environment(\.scenePhase) var scenePhase

    /// The active (non-trashed) entry matching the current selection, or `nil` when nothing is
    /// selected or the selected entry is no longer active. The detail column keys off this.
    var selectedEntry: CatalogEntry? {
        guard let selectedEntryID else { return nil }
        return catalog.active.first { $0.id == selectedEntryID }
    }

    /// The one-shot bundle for the CURRENT detail view, or nil. A live deep link (Spotlight,
    /// App Intent, a Places/favorites hit — all funnelled through `pendingPlacemarkKey`)
    /// outranks session restore; a restore bundle is only handed to the entry it was saved
    /// for (folder-name match).
    var activeRestore: RestoreBundle? {
        if let pendingPlacemarkKey {
            return RestoreBundle(routes: [.placemark(stableKey: pendingPlacemarkKey)])
        }
        if let pendingRestore, pendingRestore.entryFolderName == selectedEntry?.storageFolderName {
            return pendingRestore
        }
        return nil
    }

    init() {
        // Start on local storage (synchronously knowable). `bootstrap()` resolves the real
        // root — iCloud if sync is on and available — and switches to it.
        let cache = ResourceCache()
        _settings = State(initialValue: AppSettings())
        _resourceCache = State(initialValue: cache)
        _mapAppService = State(initialValue: MapAppService())
        _catalog = State(initialValue: Catalog(storage: .applicationSupport, cache: cache))
        let failureLog = ImportFailureLog()
        _importFailureLog = State(initialValue: failureLog)
        let coordinator = ImportCoordinator(failureLog: failureLog)
        // Held until `bootstrap()` has resolved the real storage root.
        coordinator.hold()
        _importCoordinator = State(initialValue: coordinator)
    }

    var body: some View {
        NavigationSplitView {
            HomeView(selection: $selectedEntryID, pendingPlacemarkKey: $pendingPlacemarkKey)
                // 320–380pt keeps file rows comfortable on iPad/Mac without crowding the map
                // detail; the system still lets the user drag the divider.
                .navigationSplitViewColumnWidth(min: 320, ideal: 380)
        } detail: {
            // The detail column owns its own NavigationStack so KMLDetailView's placemark and
            // map pushes stay within this column on regular width. `.id(entry.id)` forces a
            // fresh KMLDetailView identity per selection so its `@State` (document, outline,
            // annotations) resets when switching files — belt-and-braces alongside the view's
            // own `.task(id: entry.id)`.
            @Bindable var router = router
            NavigationStack(path: $router.path) {
                if let selectedEntry {
                    KMLDetailView(
                        entry: selectedEntry,
                        initialRestore: activeRestore,
                        // Consumed once by the detail view; clearing here ensures a later
                        // normal selection of the same file doesn't re-push.
                        onConsumeRestore: {
                            pendingPlacemarkKey = nil
                            pendingRestore = nil
                        }
                    )
                    .id(selectedEntry.id)
                } else {
                    ContentUnavailableView(
                        "No File Selected",
                        systemImage: "sidebar.leading",
                        description: Text("Select a file from the catalogue to view its placemarks.")
                    )
                }
            }
            // The environment bundle is applied HERE — on the detail column's NavigationStack —
            // in addition to the split view below. Pushed destinations resolve their
            // environment from the stack root, and NavigationSplitView re-hosts the detail
            // hierarchy in a different view controller on the Mac "Designed for iPad" runtime
            // (and on iPad size-class transitions), which drops values injected only on the
            // split view: PlacemarkDetailView then fatals on its non-optional MapAppService
            // read when opening a placemark in Maps. Injecting on the stack itself is the
            // pattern the pre-split-view root used and is hosting-change-proof.
            // See https://developer.apple.com/forums/thread/740872
            .modifier(AppEnvironmentBundle(
                catalog: catalog, settings: settings, mapAppService: mapAppService,
                migrationAlert: migrationAlert, importFailureLog: importFailureLog,
                resourceCache: resourceCache, router: router, importCoordinator: importCoordinator,
                syncStatus: syncStatus
            ))
        }
        .navigationSplitViewStyle(.balanced)
        .modifier(AppEnvironmentBundle(
            catalog: catalog, settings: settings, mapAppService: mapAppService,
            migrationAlert: migrationAlert, importFailureLog: importFailureLog,
            resourceCache: resourceCache, router: router, importCoordinator: importCoordinator,
            syncStatus: syncStatus
        ))
        .catalogErrorAlert(catalog)
        // Dropping .kml/.kmz files anywhere on the window imports them (C8).
        .onDrop(of: [.item], isTargeted: nil) { providers in
            handleDrop(providers)
        }
        .task { await bootstrap() }
        // Save the resume snapshot on the way OUT (`.inactive` is always passed through
        // before backgrounding — and before iOS's snapshot passes — and also fires on the
        // app-switcher path, covering swipe-kill). Pick up synced/shared files on the way IN.
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .inactive:
                saveResumeState()
            case .active:
                Task {
                    await reresolveStorageIfNeeded()
                    await drainInbox()
                    await drainDocumentsInbox()
                    await catalog.reload()
                }
            default:
                break
            }
        }
        // iCloud account changes (sign in/out, switch) can make the container appear or vanish.
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name.NSUbiquityIdentityDidChange)) { _ in
            Task { await reresolveStorageIfNeeded() }
        }
        // Handle a file opened via the KML/KMZ file-type association ("Open in Pinfold"
        // from Files/Mail/Safari) or the share extension's `pinfold://import` launch URL.
        .onOpenURL { url in
            Task { await handleOpenURL(url) }
        }
        // Apply the iCloud toggle live: switch the active root (migrating existing files)
        // and restart the watcher. No relaunch required.
        .onChange(of: settings.syncEnabled) { _, _ in
            if revertingSyncSetting {
                revertingSyncSetting = false
                return
            }
            Task { await applyStorage(migrate: true) }
        }
        // Routes are per-document: switching (or clearing) the selected file invalidates
        // the stack, matching the pre-refactor behavior where the pushed screens reset.
        // Also records the new selection immediately (crash-safety: a hard crash later in
        // the session loses at most the in-file details, never the file).
        .onChange(of: selectedEntryID) { _, _ in
            router.path = []
            // A restore bundle is only valid for the entry it was saved for: if the user
            // out-races a slow restore parse by opening another file, drop the bundle so a
            // later manual re-selection of the restored file doesn't replay it.
            if let pending = pendingRestore, pending.entryFolderName != selectedEntry?.storageFolderName {
                pendingRestore = nil
            }
            if settings.restoreSessionEnabled {
                settings.resumeEntryFolderName = selectedEntry?.storageFolderName
            }
        }
        // App Intents ("Open <file> in Pinfold") route here: the out-of-tree intent sets a
        // pending folder name on the shared router; resolve it to an active entry and select it.
        // Consume-once — clear the router so the same folder set twice still re-fires.
        .onChange(of: router.pendingEntryFolderName) { _, folderName in
            guard let folderName else { return }
            router.pendingEntryFolderName = nil
            openEntry(folderName: folderName)
        }
        // A Core Spotlight result tap arrives as a continued user activity. Parse the tapped
        // item's identifier and route into the catalogue (entry → select; placemark → select +
        // deep-link to its POI page via `pendingPlacemarkKey`, the same flow as a "Places" hit).
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            handleSpotlightActivity(activity)
        }
    }
}

// MARK: - Drag and drop

extension RootView {
    /// Stages the supported files among the dropped providers and queues them for import.
    /// Returns whether the drop was taken; unsupported files are silently ignored.
    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        Task {
            let urls = await DroppedFiles.load(providers)
            guard !urls.isEmpty else { return }
            importCoordinator.enqueueDropped(urls, catalog: catalog, cache: resourceCache)
        }
        return true
    }
}

// MARK: - Environment bundle

/// Applies the app's shared `@Observable` services and custom environment keys to a subtree.
///
/// Applied in TWO places by `RootView`: on the `NavigationSplitView` (sidebar, sheets) and
/// again on the detail column's `NavigationStack`. The duplication is deliberate and
/// load-bearing — `NavigationSplitView` re-hosts the detail hierarchy in a different view
/// controller on the Mac "Designed for iPad" runtime and on iPad size-class transitions,
/// which drops environment values injected only on the split view from *pushed* destinations
/// (https://developer.apple.com/forums/thread/740872). Injecting on the stack root keeps
/// pushes supplied through any re-hosting, matching the pre-split-view root's proven pattern.
private struct AppEnvironmentBundle: ViewModifier {
    let catalog: Catalog
    let settings: AppSettings
    let mapAppService: MapAppService
    let migrationAlert: MigrationAlertState
    let importFailureLog: ImportFailureLog
    let resourceCache: ResourceCache
    let router: NavigationRouter
    let importCoordinator: ImportCoordinator
    let syncStatus: SyncStatus

    func body(content: Content) -> some View {
        content
            .environment(catalog)
            .environment(settings)
            .environment(mapAppService)
            .environment(migrationAlert)
            .environment(importFailureLog)
            .environment(router)
            .environment(importCoordinator)
            .environment(syncStatus)
            .environment(\.resourceCache, resourceCache)
            .environment(\.storageLocations, catalog.storage)
    }
}
