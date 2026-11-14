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
/// remote URL; Select sits in its own pill before the Settings gear on both segments.
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
    /// Stop Updating asked for from the menu bar. It has its own screen-level confirmation, as
    /// the open file's row (which hosts the row-originated one) may not be on screen: Trash
    /// shown, filtered out by a search, or scrolled away.
    @State var menuStopUpdatingTarget: CatalogEntry?
    @State var refreshError: String?
    /// Presents the Settings sheet. Settings is a modal sheet (not a pushed/detail screen) so
    /// it covers the whole window on iPad/Mac rather than landing in one split column.
    @State var isSettingsPresented = false

    /// Whether the Files or Trash list is in explicit multi-select mode (C8). The Files list
    /// then binds `bulkSelection` instead of `selection`, so picking rows never drives the
    /// detail column.
    @State var isSelecting = false
    /// The ids ticked in select mode.
    @State var bulkSelection: Set<CatalogEntry.ID> = []

    /// The search query, bound to the `.searchable` field: on Files it searches file names and
    /// every file's places; on Trash it filters the rows by name.
    @State var searchQuery = ""
    /// Keyboard focus for the search field, driven by the ⌘F command (see `WindowCommands`).
    @FocusState var isSearchFocused: Bool
    /// "Places" hits for the current query, read off-main from each active entry's local
    /// `placemarks-index.json`. Empty when the query is empty or matches no placemark.
    /// Not `private`: `groupedPlaceHits` lives in the `HomeView+Sections` extension (a separate file).
    @State var placeHits: [PlacemarkIndex.Hit] = []
    /// Favourites / Seen for the files the "Places" hits come from, by folder name, so a hit
    /// offers the same actions as the place inside its file. Rebuilt with each search (which
    /// re-runs when any sidecar changes, via `searchDataRevision`).
    @State var hitAnnotations: [String: PlacemarkAnnotations] = [:]

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

    /// Trimmed query; non-empty means Files shows search results instead of the plain list and
    /// Trash shows only the matching rows.
    var trimmedQuery: String {
        searchQuery.trimmingCharacters(in: .whitespaces)
    }

    var isSearching: Bool {
        segment == .files && !trimmedQuery.isEmpty
    }

    /// Trash, narrowed to the names matching the search query (Trash is searched by name; it
    /// has no place results). The whole Trash when the query is empty.
    var visibleTrashed: [CatalogEntry] {
        let query = trimmedQuery
        guard !query.isEmpty else { return trashed }
        // The same matching as Files search (ignores case, accents and width).
        return trashed.filter { SearchText.contains($0.displayName, query: query) }
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
        // Files searches file names and every file's places; Trash filters its rows by name.
        // `.searchable` is the iOS 26 native placement; `.searchFocused` lets the ⌘F command
        // move keyboard focus here.
        .searchable(
            text: $searchQuery,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: segment == .files ? Text("Search files and places") : Text("Search Trash")
        )
        .searchFocused($isSearchFocused)
        // Debounced, off-main search over each active entry's local placemark index. Re-keys on
        // the query AND the segment so returning to Files with a live query recomputes the hits
        // (Trash filters by name only, without this task). Single trigger — simpler than KMLDetailView's two-trigger
        // split, which existed only to handle un-debounced collapse toggles.
        .task(id: SearchTrigger(query: searchQuery, segment: segment, dataRevision: catalog.searchDataRevision)) {
            let query = trimmedQuery
            guard segment == .files, !query.isEmpty else {
                placeHits = []
                hitAnnotations = [:]
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
            hitAnnotations = annotationsForHits(hits)
        }
        // Menu commands act on THIS window only: published as a focused-scene value.
        .focusedSceneValue(\.windowCommands, windowCommands)
        .stopUpdatingConfirmation(target: $menuStopUpdatingTarget, stop: runStopUpdating)
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
        .onChange(of: canSelect) { _, allowed in
            if !allowed {
                endSelecting()
            }
        }
        // A selection belongs to one segment's list; switching segments leaves select mode.
        .onChange(of: segment) { endSelecting() }
        // Settings as a modal sheet (was a pushed NavigationLink under the old single-stack
        // root). A sheet keeps Settings full-window on iPad/Mac instead of landing in one
        // split column, and wraps it in its own NavigationStack so its title bar renders.
        .sheet(isPresented: $isSettingsPresented) {
            NavigationStack {
                SettingsView()
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(role: .close) { isSettingsPresented = false }
                        }
                    }
            }
        }
        // Inbox draining (share-extension handoff) is performed once in RootView's
        // .task on launch; it is intentionally NOT duplicated here.
    }
}
