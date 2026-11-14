import SwiftUI
import UniformTypeIdentifiers

// MARK: - Segment

enum Segment: Hashable {
    case files
    case trash
}

// MARK: - HomeView

/// The root screen of Pinfold.
///
/// Shows a segmented Files / Trash list. The "+" toolbar menu imports a local file or follows a
/// remote URL; Select (Files) or Empty (Trash) sits in its own pill before the Settings gear.
///
/// Layout: the `NavigationTitle` "Pinfold" stays in the nav bar; the segmented Picker
/// lives in a `safeAreaInset` bar above the List so it never replaces the title; empty
/// states are shown as `overlay`s on the List so `ContentUnavailableView` has the full
/// view bounds it needs to centre itself.
struct HomeView: View {
    // MARK: - Bindings

    /// The catalogue selection, owned by `RootView` (drives the detail column). Stored by
    /// entry id so it survives `catalog.reload()`; see `RootView.selectedEntryID`.
    @Binding var selection: CatalogEntry.ID?

    /// One-shot deep-link target, owned by `RootView`. Set (together with `selection`) when the
    /// user taps a catalogue-wide "Places" search hit so the opened file pushes straight to that
    /// placemark's detail page. Left nil for ordinary file taps. See `RootView`.
    @Binding var pendingPlacemarkKey: String?

    // MARK: - Environment

    // Not `private`: the extensions in other files (rows, banner, toolbar) read these.
    @Environment(Catalog.self) var catalog
    @Environment(ImportFailureLog.self) var importFailureLog
    @Environment(\.resourceCache) var resourceCache
    /// The shared import queue, owned by `RootView`.
    @Environment(ImportCoordinator.self) var importCoordinator
    /// Whether rows show a chevron (the split view is collapsed into one stack).
    @Environment(\.showsRowDisclosure) var showsRowDisclosure

    // MARK: - Local state

    @State var segment: Segment = .files
    /// Presents the `fileImporter` picker sheet. Distinct from
    /// `importCoordinator.isImporting`, which tracks the import *pipeline* being busy.
    @State var isFileImporterPresented = false
    /// Remote URL: the alert, its text, a download in flight, and the error to show.
    @State var subscribePrompt = SubscribePrompt()
    @State var isSubscribing = false
    @Environment(SubscriptionRefresher.self) var refresher
    /// The online list awaiting a Stop Updating confirmation, and a failed Refresh Now's error.
    @State var stopUpdatingTarget: CatalogEntry?
    @State var refreshError: String?
    /// Presents the Settings sheet. Settings is a modal sheet (not a pushed/detail screen) so
    /// it covers the whole window on iPad/Mac rather than landing in one split column.
    @State var isSettingsPresented = false
    /// Presents the Empty Trash confirmation, anchored to the toolbar's Empty button.
    @State var isConfirmingEmptyTrash = false

    /// The entry currently being renamed (drives the rename alert), or `nil` when no rename is
    /// in progress. Set from the active-row context menu's "Rename" action (in HomeViewRows).
    @State var renameTarget: CatalogEntry?
    /// The editable text bound to the rename alert's `TextField`, prefilled with the entry's
    /// current name when the alert opens.
    @State var renameText = ""

    /// Whether the Files list is in explicit multi-select mode (C8). The list then binds
    /// `bulkSelection` instead of `selection`, so picking rows never drives the detail column.
    @State var isSelecting = false
    /// The ids ticked in select mode.
    @State var bulkSelection: Set<CatalogEntry.ID> = []

    /// Catalogue-wide search query, bound to the `.searchable` field (Files segment only).
    @State var searchQuery = ""
    /// Keyboard focus for the search field, driven by the ⌘F command (see `WindowCommands`).
    @FocusState var isSearchFocused: Bool
    /// "Places" hits for the current query, read off-main from each active entry's local
    /// `placemarks-index.json`. Empty when the query is empty or matches no placemark.
    /// Not `private`: `groupedPlaceHits` lives in the `HomeView+Sections` extension (a separate file).
    @State var placeHits: [PlacemarkIndex.Hit] = []

    /// Debounce before reading every entry's index off disk, matching `KMLDetailView`'s
    /// in-file search debounce so rapid typing doesn't fan out a read storm.
    private static let searchDebounce: Duration = .milliseconds(250)

    /// Identity for the search `.task`: the query plus the active segment. Re-running on a
    /// segment change lets Files repopulate its hits after a detour through Trash.
    private struct SearchTrigger: Equatable {
        let query: String
        let segment: Segment
        /// `Catalog.searchDataRevision`: re-search after notes/sidecars change on disk.
        let dataRevision: Int
    }

    // MARK: - Computed partitions

    var active: [CatalogEntry] {
        catalog.active
    }

    /// `active`, newest import first: the order of the Files list, select mode and the "Files"
    /// search-results section.
    var sortedActive: [CatalogEntry] {
        CatalogOrder.newestFirst(active)
    }

    var trashed: [CatalogEntry] {
        catalog.trashed
    }

    /// Trimmed query; non-empty means the Files segment shows search results instead of the
    /// plain entry list. Trash is never searched (active entries only).
    var trimmedQuery: String {
        searchQuery.trimmingCharacters(in: .whitespaces)
    }

    var isSearching: Bool {
        segment == .files && !trimmedQuery.isEmpty
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            SyncStatusBanner()
            pickerBar
            importFailureBanner
            fileList
        }
        .navigationTitle("Pinfold")
        // Catalogue-wide search lives only on the Files segment (active entries); Trash is not
        // searched. `.searchable` is the iOS 26 native placement; `.searchFocused` lets the ⌘F
        // command move keyboard focus here.
        .searchable(
            text: $searchQuery,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: Text("Search files and places")
        )
        .searchFocused($isSearchFocused)
        // Debounced, off-main search over each active entry's local placemark index. Re-keys on
        // the query AND the segment so returning to Files with a live query recomputes the hits
        // (Trash isn't searched). Single trigger — simpler than KMLDetailView's two-trigger
        // split, which existed only to handle un-debounced collapse toggles.
        .task(id: SearchTrigger(query: searchQuery, segment: segment, dataRevision: catalog.searchDataRevision)) {
            let query = trimmedQuery
            guard segment == .files, !query.isEmpty else {
                placeHits = []
                return
            }
            try? await Task.sleep(for: Self.searchDebounce)
            if Task.isCancelled {
                return
            }
            // Snapshot the (folderName, resourcesDir) pairs on the main actor, then read the
            // index files off-main — the read is pure disk I/O over Sendable URLs.
            let sources = active.map {
                PlacemarkIndex.Source(
                    folderName: $0.storageFolderName,
                    resourcesDir: catalog.storage.resourcesDirectory(for: $0),
                    sidecarURL: catalog.storage.metadataFile(for: $0)
                )
            }
            let hits = await Task.detached(priority: .userInitiated) {
                PlacemarkIndex.search(query, in: sources)
            }.value
            if Task.isCancelled {
                return
            }
            placeHits = hits
        }
        // Menu commands act on THIS window only: published as a focused-scene value.
        .focusedSceneValue(\.windowCommands, windowCommands)
        .toolbar { toolbarContent }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: ImportFormats.allowedContentTypes,
            allowsMultipleSelection: true
        ) { result in
            handleFileImporterResult(result)
        }
        .modifier(ImportAlertsModifier(importCoordinator: importCoordinator))
        .modifier(SubscribeAlertsModifier(
            prompt: $subscribePrompt, isSubscribing: isSubscribing, subscribe: runSubscribe
        ))
        .modifier(OnlineListDialogsModifier(refreshError: $refreshError))
        // Rename alert — a single TextField prefilled with the current name. `presenting` keys
        // the alert to the entry being renamed; Save commits the trimmed name via
        // `catalog.rename` (which rejects an empty/whitespace name as a no-op).
        .alert(
            "Rename File",
            isPresented: Binding(
                get: { renameTarget != nil },
                set: {
                    if !$0 {
                        renameTarget = nil
                    }
                }
            ),
            presenting: renameTarget
        ) { entry in
            TextField("Name", text: $renameText)
            Button("Save") {
                let newName = renameText
                Task { await catalog.rename(entry, to: newName) }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .onChange(of: canSelect) { _, allowed in
            if !allowed {
                endSelecting()
            }
        }
        // Settings as a modal sheet (was a pushed NavigationLink under the old single-stack
        // root). A sheet keeps Settings full-window on iPad/Mac instead of landing in one
        // split column, and wraps it in its own NavigationStack so its title bar renders.
        .sheet(isPresented: $isSettingsPresented) {
            NavigationStack {
                SettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(role: .close) { isSettingsPresented = false }
                        }
                    }
            }
        }
        // Inbox draining (share-extension handoff) is performed once in RootView's
        // .task on launch; it is intentionally NOT duplicated here.
    }
}
