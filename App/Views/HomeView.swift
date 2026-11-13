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
/// Shows a segmented Files / Trash list. The "+" toolbar button opens a `fileImporter`
/// to pick KML/KMZ files. The gear toolbar button presents Settings as a modal sheet.
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

    // Not `private`: read from the `HomeViewRows` extension (a separate file) for the
    // active-row context menu (Share/Trash).
    @Environment(Catalog.self) var catalog
    @Environment(AppSettings.self) var settings
    // Not `private`: read from the `HomeViewBanner` extension (a separate file).
    @Environment(ImportFailureLog.self) var importFailureLog
    @Environment(\.resourceCache) var resourceCache
    /// The shared import queue, owned by `RootView`.
    @Environment(ImportCoordinator.self) var importCoordinator

    // MARK: - Local state

    /// Not `private`: read from the `HomeViewTags` extension (a separate file) for the chips bar.
    @State var segment: Segment = .files
    /// Presents the `fileImporter` picker sheet. Distinct from
    /// `importCoordinator.isImporting`, which tracks the import *pipeline* being busy.
    @State var isFileImporterPresented = false
    /// Subscribe to URL: the alert, its text, a download in flight, and the error to show.
    @State var isSubscribeAlertPresented = false
    @State var subscribeText = ""
    @State var isSubscribing = false
    @State var subscribeError: String?
    @Environment(SubscriptionRefresher.self) var refresher
    /// Presents the Settings sheet. Settings is a modal sheet (not a pushed/detail screen) so
    /// it covers the whole window on iPad/Mac rather than landing in one split column.
    @State var isSettingsPresented = false
    /// Presents the consolidated Favorites sheet (catalogue-wide starred placemarks). A sheet,
    /// like Settings, so it covers the whole window; tapping a favorite dismisses it and drives
    /// the sidebar selection + deep-link.
    @State var isFavoritesPresented = false

    /// The entry currently being renamed (drives the rename alert), or `nil` when no rename is
    /// in progress. Set from the active-row context menu's "Rename" action (in HomeViewRows).
    @State var renameTarget: CatalogEntry?
    /// The editable text bound to the rename alert's `TextField`, prefilled with the entry's
    /// current name when the alert opens.
    @State var renameText = ""

    /// The entry currently having its tags edited (drives the tags alert), or `nil`. Set from
    /// the active-row context menu's "Edit Tags…" action (in HomeViewRows).
    @State var tagsTarget: CatalogEntry?
    /// The editable, comma-separated tags text bound to the tags alert's `TextField`, prefilled
    /// by joining the entry's current tags with ", ". Parsed back by comma on Save.
    @State var tagsText = ""

    /// Whether the Files list is in explicit multi-select mode (C8). The list then binds
    /// `bulkSelection` instead of `selection`, so picking rows never drives the detail column.
    @State var isSelecting = false
    /// The ids ticked in select mode.
    @State var bulkSelection: Set<CatalogEntry.ID> = []
    /// The entries a bulk "Tag" is about to be applied to (drives the shared tags alert).
    @State var bulkTagTargets: [CatalogEntry]?
    /// The editable text for the bulk tags alert.
    @State var bulkTagsText = ""

    /// The currently-selected filter chip tag (Files segment), or `nil` for "All". Hidden while
    /// searching (chips are not shown during search to keep filter state simple).
    /// Not `private`: read/written from the `HomeViewTags` extension (a separate file).
    @State var selectedTag: String?

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

    /// `active` reordered by the user's chosen sort. This is the presentation order for the
    /// Files list and the "Files" search-results section; the catalogue's storage order
    /// (newest-first, from the scanner) is unchanged — sorting is purely a view concern.
    var sortedActive: [CatalogEntry] {
        settings.entrySort.apply(to: active)
    }

    var trashed: [CatalogEntry] {
        catalog.trashed
    }

    /// Trimmed query; non-empty means the Files segment shows search results instead of the
    /// plain entry list. Trash is never searched (active entries only).
    var trimmedQuery: String {
        searchQuery.trimmingCharacters(in: .whitespaces)
    }

    /// Not `private`: read from the `HomeViewTags` extension (a separate file).
    var isSearching: Bool {
        segment == .files && !trimmedQuery.isEmpty
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            SyncStatusBanner()
            pickerBar
            tagChipsBar
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
        // Reset a stale tag filter when its tag vanishes. MUST hang off the always-mounted
        // body, not `tagChipsBar` (which unmounts when the last tag goes — see HomeViewTags).
        .onChange(of: allTags) { _, tags in
            resetStaleTagFilter(tags)
        }
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
            isPresented: $isSubscribeAlertPresented, text: $subscribeText,
            error: $subscribeError, isSubscribing: isSubscribing, subscribe: runSubscribe
        ))
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
        // Edit Tags alert — the full alert tree lives in `EditTagsAlertModifier`
        // (HomeViewTags.swift) so this body chain stays inside the type-checker's budget.
        .modifier(EditTagsAlertModifier(target: $tagsTarget, text: $tagsText, save: saveTags))
        .modifier(EditTagsAlertModifier(
            target: $bulkTagTargets, text: $bulkTagsText, title: "Add Tags", save: saveBulkTags
        ))
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
                            Button("Done") { isSettingsPresented = false }
                        }
                    }
            }
        }
        // Consolidated Favorites as a modal sheet. It owns its own NavigationStack (title +
        // Done). Tapping a favorite dismisses the sheet and drives the same selection +
        // `pendingPlacemarkKey` deep-link the catalogue "Places" search hits use.
        .sheet(isPresented: $isFavoritesPresented) {
            FavoritesView(selection: $selection, pendingPlacemarkKey: $pendingPlacemarkKey)
        }
        // Inbox draining (share-extension handoff) is performed once in RootView's
        // .task on launch; it is intentionally NOT duplicated here.
    }
}
