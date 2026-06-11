import os
import SwiftUI

@main
struct PinfoldApp: App {
    /// Bridges the "Import…" menu command to `HomeView`'s file importer (see `AppCommands`).
    @State private var appCommands = AppCommands()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appCommands)
        }
        .commands {
            // ⌘I mirrors HomeView's "+" toolbar button. Placed after the standard "New"
            // group so it sits with the file-creation commands in the menu bar (Mac /
            // hardware-keyboard iPad). The flag-bump is observed by HomeView, which owns
            // the fileImporter — Commands can't present sheets directly.
            CommandGroup(after: .newItem) {
                Button("Import\u{2026}") {
                    appCommands.requestImport()
                }
                .keyboardShortcut("i", modifiers: .command)
            }
            // No "Search" command: there is no catalogue-wide search field yet (global
            // search is a later task — see plan task 26). Adding a ⌘F no-op now would be
            // speculative plumbing, so it is intentionally omitted until that field exists.
        }
    }
}

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
private struct RootView: View {
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

    @State private var settings: AppSettings
    @State private var catalog: Catalog
    @State private var mapAppService: MapAppService
    @State private var resourceCache: ResourceCache
    @State private var watcher: CatalogWatcher?
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
            HomeView(selection: $selectedEntryID)
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
                    KMLDetailView(entry: selectedEntry)
                        .id(selectedEntry.id)
                } else {
                    ContentUnavailableView(
                        "No File Selected",
                        systemImage: "sidebar.leading",
                        description: Text("Select a file from the catalogue to view its placemarks.")
                    )
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .environment(catalog)
        .environment(settings)
        .environment(mapAppService)
        .environment(migrationAlert)
        .environment(importFailureLog)
        .environment(\.resourceCache, resourceCache)
        .environment(\.storageLocations, catalog.storage)
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
    }

    /// One-time startup: resolve the active root, drain the inbox, reload, start watching.
    private func bootstrap() async {
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
