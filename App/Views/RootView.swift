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
    private static let migrationLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Pinfold",
        category: "migration"
    )

    /// Diagnostics for "Open in Pinfold" import failures. The user-facing failure banner
    /// carries only friendly reasons; the underlying errors go here.
    private static let importLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Pinfold",
        category: "import"
    )

    /// Diagnostics for deep-link routing (App Intents + Spotlight taps) that resolve to a
    /// missing/trashed entry — surfaced here rather than to the user (a no-op is fine).
    private static let routingLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Pinfold",
        category: "spotlight"
    )

    @State private var settings: AppSettings
    @State private var catalog: Catalog
    @State private var mapAppService: MapAppService
    @State private var resourceCache: ResourceCache
    @State private var watcher: CatalogWatcher?
    /// Deep-link sink for App Intents (and any future programmatic navigation). Published to
    /// `AppDependencies` at bootstrap so the out-of-tree `OpenEntryIntent` can drive selection.
    @State private var router = NavigationRouter()
    /// Surfaces partial-migration failures to the Settings flow as an alert.
    @State private var migrationAlert = MigrationAlertState()
    /// Surfaces import failures (parse or I/O) from every arrival path to `HomeView`.
    @State private var importFailureLog = ImportFailureLog()
    /// Whether the catalogue's current root is the iCloud (ubiquitous) container. Tracked so
    /// migrations pick the right file API (`setUbiquitous` vs `moveItem`).
    @State private var rootIsUbiquitous = false

    /// The sidebar selection, stored by **entry id** rather than by value. `CatalogEntry` is a
    /// value type rebuilt from disk on every `catalog.reload()`, so a stored value would go
    /// stale (and break `List` selection equality) after any reload, trash, or rename. Storing
    /// the stable `UUID` and resolving it against `catalog.entries` keeps the selection alive
    /// across reloads, and naturally clears it when the entry disappears (deleted) or is
    /// trashed (the sidebar only exposes active entries for selection).
    @State private var selectedEntryID: CatalogEntry.ID?

    /// A one-shot search string handed to the detail view when a selection is triggered by a
    /// catalogue-wide "Places" search hit (see `HomeView`). It carries the tapped placemark's
    /// NAME so `KMLDetailView` opens with its in-file outline pre-filtered to that placemark.
    ///
    /// Consume-once flow: `HomeView` sets this AND `selectedEntryID` together when a hit is
    /// tapped; this view passes it into `KMLDetailView(initialSearch:)`, then clears it in the
    /// detail's `.task(id:)` lifetime by resetting it whenever the selection changes. A normal
    /// row tap only changes `selectedEntryID` (leaving this nil), so it does not pre-filter.
    @State private var pendingDetailSearch: String?

    @Environment(\.scenePhase) private var scenePhase

    /// The active (non-trashed) entry matching the current selection, or `nil` when nothing is
    /// selected or the selected entry is no longer active. The detail column keys off this.
    private var selectedEntry: CatalogEntry? {
        guard let selectedEntryID else { return nil }
        return catalog.active.first { $0.id == selectedEntryID }
    }

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
        NavigationSplitView {
            HomeView(selection: $selectedEntryID, pendingDetailSearch: $pendingDetailSearch)
                // 320–380pt keeps file rows comfortable on iPad/Mac without crowding the map
                // detail; the system still lets the user drag the divider.
                .navigationSplitViewColumnWidth(min: 320, ideal: 380)
        } detail: {
            // The detail column owns its own NavigationStack so KMLDetailView's placemark and
            // map pushes stay within this column on regular width. `.id(entry.id)` forces a
            // fresh KMLDetailView identity per selection so its `@State` (document, outline,
            // annotations) resets when switching files — belt-and-braces alongside the view's
            // own `.task(id: entry.id)`.
            NavigationStack {
                if let selectedEntry {
                    KMLDetailView(
                        entry: selectedEntry,
                        initialSearch: pendingDetailSearch,
                        // Consumed once by the detail view's load `.task`; clearing here ensures
                        // a later normal selection of the same file doesn't re-apply the filter.
                        onConsumeInitialSearch: { pendingDetailSearch = nil }
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
                resourceCache: resourceCache
            ))
        }
        .navigationSplitViewStyle(.balanced)
        .modifier(AppEnvironmentBundle(
            catalog: catalog, settings: settings, mapAppService: mapAppService,
            migrationAlert: migrationAlert, importFailureLog: importFailureLog,
            resourceCache: resourceCache
        ))
        .task { await bootstrap() }
        // Pick up files synced or shared while the app was already running.
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await drainInbox(); await drainDocumentsInbox(); await catalog.reload() }
            }
        }
        // Handle a file opened via the KML/KMZ file-type association ("Open in Pinfold"
        // from Files/Mail/Safari) or the share extension's `pinfold://import` launch URL.
        .onOpenURL { url in
            Task { await handleOpenURL(url) }
        }
        // Apply the iCloud toggle live: switch the active root (migrating existing files)
        // and restart the watcher. No relaunch required.
        .onChange(of: settings.syncEnabled) { _, _ in
            Task { await applyStorage(migrate: true) }
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
        // pre-filter the outline to the placemark name, the same flow as a "Places" search hit).
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            Task { await handleSpotlightActivity(activity) }
        }
    }

    // MARK: - Deep-link routing (App Intents + Spotlight)

    /// Selects the active entry with `folderName`, or logs and no-ops when it's missing/trashed.
    private func openEntry(folderName: String) {
        guard let entry = catalog.active.first(where: { $0.storageFolderName == folderName }) else {
            Self.routingLogger.info(
                "Deep link to missing/trashed entry '\(folderName, privacy: .public)' — ignored."
            )
            return
        }
        pendingDetailSearch = nil
        selectedEntryID = entry.id
    }

    /// Handles a Core Spotlight result tap. The identifier is the tapped item's `SpotlightID`:
    /// an entry item selects its file; a placemark item selects the file AND pre-filters its
    /// outline to the placemark's name (resolved off-main from the entry's `placemarks-index.json`).
    private func handleSpotlightActivity(_ activity: NSUserActivity) async {
        guard let raw = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              let parsed = SpotlightID.parse(raw)
        else { return }

        guard let entry = catalog.active.first(where: { $0.storageFolderName == parsed.folderName }) else {
            Self.routingLogger.info(
                "Spotlight tap on missing/trashed entry '\(parsed.folderName, privacy: .public)' — ignored."
            )
            return
        }

        if let placemarkKey = parsed.placemarkKey {
            // Resolve the placemark name off-main via the free function (kept out of the view's
            // SIL — its `Task.detached` lives in `readPlacemarkName`, mirroring `FavoritesView`),
            // then drive the existing consume-once outline pre-filter.
            let resourcesDir = catalog.storage.resourcesDirectory(for: entry)
            let name = await readPlacemarkName(forKey: placemarkKey, in: resourcesDir)
            pendingDetailSearch = (name?.isEmpty == false) ? name : nil
        } else {
            pendingDetailSearch = nil
        }
        selectedEntryID = entry.id
    }

    /// One-time startup: resolve the active root, drain the inbox, reload, start watching.
    private func bootstrap() async {
        // Publish the live services so out-of-tree App Intents can resolve entities and route.
        AppDependencies.shared.catalog = catalog
        AppDependencies.shared.router = router
        await applyStorage(migrate: false)
        await drainInbox()
        await drainDocumentsInbox()
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
            // Run the move off-main, then surface any per-folder failures. We do NOT swallow
            // the report: a folder that fails to move stays in the old root and would silently
            // vanish from the catalogue otherwise. Enumeration/setup errors (the only thrown
            // path) leave `report` nil and are best-effort ignored — the repoint below still
            // happens so the app keeps working against the resolved root.
            let report = try? await Task.detached {
                try StorageLocations.migrateEntryFolders(
                    from: from,
                    to: storage.root,
                    fromUbiquitous: wasUbiquitous,
                    toUbiquitous: ubiquitous
                )
            }.value
            if let report, !report.failed.isEmpty {
                // Log each underlying error so failed folders are diagnosable from the
                // console; the user-facing alert below only carries the entry names.
                for failure in report.failed {
                    Self.migrationLogger.error(
                        """
                        Failed to migrate entry folder \
                        '\(failure.folderName, privacy: .public)': \
                        \(failure.error.localizedDescription, privacy: .public)
                        """
                    )
                }
                // Map failed folder names to display names via the still-current (pre-repoint)
                // catalogue; fall back to the raw folder name when no entry is loaded for it.
                let byFolder = Dictionary(
                    catalog.entries.map { ($0.storageFolderName, $0.displayName) },
                    uniquingKeysWith: { first, _ in first }
                )
                let names = report.failed.map { byFolder[$0.folderName] ?? $0.folderName }
                migrationAlert.report(failedNames: names)
            }
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
            cache: resourceCache,
            failureLog: importFailureLog
        )
        await inbox.drain()
    }

    // MARK: - Document open ("Open in Pinfold")

    /// The app-sandbox `Documents/Inbox` directory that iOS copies opened documents into
    /// (the app declares the KML/KMZ types with open-in-place disabled). Distinct from the
    /// App Group inbox the share extension uses.
    private var documentsInboxURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Inbox", isDirectory: true)
    }

    /// Handles a URL handed to the app via the file-type association or a custom scheme.
    /// A file URL is imported directly — it is authoritative and already in our sandbox, so
    /// relying only on a directory scan could silently drop it — then both inboxes are
    /// drained for any stragglers.
    private func handleOpenURL(_ url: URL) async {
        if url.isFileURL {
            await importFile(at: url)
        }
        await drainDocumentsInbox()
        await drainInbox()
    }

    /// Imports a single opened file, deduping by content hash, reporting failures to the log.
    ///
    /// Failure handling mirrors `PendingImportInbox.drain`:
    /// - **Read / parse failure** is permanent (bad bytes), so the sandbox copy is deleted and
    ///   the failure recorded — retrying never helps.
    /// - **Commit (I/O) failure** is potentially transient, so the sandbox copy is KEPT. The
    ///   opened document is a copy iOS placed in `Documents/Inbox` (open-in-place is disabled
    ///   for our KML/KMZ types), and `handleOpenURL` always drains that inbox afterwards, so a
    ///   kept file is retried by `drainDocumentsInbox`. If a future caller ever passes a URL
    ///   from outside `Documents/Inbox`, the kept file simply isn't retried automatically — but
    ///   the failure is still surfaced to the user, so nothing is lost silently.
    /// On success the sandbox copy is deleted.
    private func importFile(at url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let data: Data
        let result: ImportResult
        do {
            data = try Data(contentsOf: url)
            result = try ImportService.prepare(data: data, sourceFilename: url.lastPathComponent)
        } catch {
            // Read or parse failure — permanent. Record and delete the copy; the underlying
            // cause goes to the console log.
            Self.importLogger.error(
                """
                Failed to read or parse opened file \
                '\(url.lastPathComponent, privacy: .public)': \
                \(error.localizedDescription, privacy: .public)
                """
            )
            importFailureLog.record(
                filename: url.lastPathComponent,
                reason: String(
                    localized: "Not a valid KML or KMZ file.",
                    comment: "Import failure reason: the file could not be read or parsed."
                )
            )
            try? FileManager.default.removeItem(at: url)
            return
        }

        if catalog.entry(withSHA256: result.contentSHA256) == nil {
            do {
                try ImportService.commit(result, storage: catalog.storage, cache: resourceCache)
                await catalog.reload()
            } catch {
                // Commit (I/O) failure — potentially transient. Record a friendly reason (the
                // raw error is developer-speak) but KEEP the copy so the Documents-inbox drain
                // can retry it; the underlying error goes to the console log.
                Self.importLogger.error(
                    """
                    Transient failure importing opened file \
                    '\(url.lastPathComponent, privacy: .public)': \
                    \(error.localizedDescription, privacy: .public)
                    """
                )
                importFailureLog.record(
                    filename: url.lastPathComponent,
                    reason: String(
                        localized: "Couldn't save the file. It will be retried automatically.",
                        comment: "Import failure reason: a transient I/O error; the import will be retried."
                    )
                )
                return
            }
        }
        // Imported or deduped — the sandbox copy is safe to delete.
        try? FileManager.default.removeItem(at: url)
    }

    /// Drains the app's `Documents/Inbox` (files opened via the KML/KMZ file-type association).
    private func drainDocumentsInbox() async {
        guard let documentsInboxURL else { return }
        let inbox = PendingImportInbox(
            inboxURL: documentsInboxURL,
            catalog: catalog,
            storage: catalog.storage,
            cache: resourceCache,
            failureLog: importFailureLog
        )
        await inbox.drain()
    }
}

// MARK: - Off-main placemark name lookup

/// Reads the name of the placemark with `key` from the `placemarks-index.json` in
/// `resourcesDir`, off the main actor. Returns `nil` if the index is absent or the key isn't
/// found. A top-level `nonisolated` function (not a method on the `@MainActor` view) so the
/// `Task.detached` closure compiles outside the view's SIL — see `FavoritesView.load()`.
private func readPlacemarkName(forKey key: String, in resourcesDir: URL) async -> String? {
    await Task.detached(priority: .userInitiated) {
        PlacemarkIndex.read(from: resourcesDir)?.first { $0.key == key }?.name
    }.value
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

    func body(content: Content) -> some View {
        content
            .environment(catalog)
            .environment(settings)
            .environment(mapAppService)
            .environment(migrationAlert)
            .environment(importFailureLog)
            .environment(\.resourceCache, resourceCache)
            .environment(\.storageLocations, catalog.storage)
    }
}
