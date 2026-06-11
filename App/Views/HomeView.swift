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

    /// One-shot deep-link search string, owned by `RootView`. Set (together with `selection`)
    /// when the user taps a catalogue-wide "Places" search hit so the opened file's outline
    /// pre-filters to that placemark. Left nil for ordinary file taps. See `RootView`.
    @Binding var pendingDetailSearch: String?

    // MARK: - Environment

    // Not `private`: read from the `HomeViewRows` extension (a separate file) for the
    // active-row context menu (Share/Trash).
    @Environment(Catalog.self) var catalog
    @Environment(AppSettings.self) private var settings
    // Not `private`: read from the `HomeViewBanner` extension (a separate file).
    @Environment(ImportFailureLog.self) var importFailureLog
    @Environment(AppCommands.self) private var appCommands
    @Environment(\.resourceCache) private var resourceCache

    // MARK: - Local state

    /// Not `private`: read from the `HomeViewTags` extension (a separate file) for the chips bar.
    @State var segment: Segment = .files
    /// Presents the `fileImporter` picker sheet. Distinct from
    /// `importCoordinator.isImporting`, which tracks the import *pipeline* being busy.
    @State private var isFileImporterPresented = false
    /// Presents the Settings sheet. Settings is a modal sheet (not a pushed/detail screen) so
    /// it covers the whole window on iPad/Mac rather than landing in one split column.
    @State private var isSettingsPresented = false
    /// Presents the consolidated Favorites sheet (catalogue-wide starred placemarks). A sheet,
    /// like Settings, so it covers the whole window; tapping a favorite dismisses it and drives
    /// the sidebar selection + deep-link.
    @State private var isFavoritesPresented = false
    @State private var importCoordinator = ImportCoordinator()

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

    /// The currently-selected filter chip tag (Files segment), or `nil` for "All". Hidden while
    /// searching (chips are not shown during search to keep filter state simple).
    /// Not `private`: read/written from the `HomeViewTags` extension (a separate file).
    @State var selectedTag: String?

    /// Catalogue-wide search query, bound to the `.searchable` field (Files segment only).
    @State private var searchQuery = ""
    /// Keyboard focus for the search field, driven by the ⌘F command (see `AppCommands`).
    @FocusState private var isSearchFocused: Bool
    /// "Places" hits for the current query, read off-main from each active entry's local
    /// `placemarks-index.json`. Empty when the query is empty or matches no placemark.
    /// Not `private`: `groupedPlaceHits` lives in the `HomeSearchResults` extension (a separate file).
    @State var placeHits: [PlacemarkIndex.Hit] = []

    /// Debounce before reading every entry's index off disk, matching `KMLDetailView`'s
    /// in-file search debounce so rapid typing doesn't fan out a read storm.
    private static let searchDebounce: Duration = .milliseconds(250)

    /// Identity for the search `.task`: the query plus the active segment. Re-running on a
    /// segment change lets Files repopulate its hits after a detour through Trash.
    private struct SearchTrigger: Equatable {
        let query: String
        let segment: Segment
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

    private var trashed: [CatalogEntry] {
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
        .task(id: SearchTrigger(query: searchQuery, segment: segment)) {
            let query = trimmedQuery
            guard segment == .files, !query.isEmpty else {
                placeHits = []
                return
            }
            try? await Task.sleep(for: Self.searchDebounce)
            if Task.isCancelled { return }
            // Snapshot the (folderName, resourcesDir) pairs on the main actor, then read the
            // index files off-main — the read is pure disk I/O over Sendable URLs.
            let dirs = active.map {
                (folderName: $0.storageFolderName, resourcesDir: catalog.storage.resourcesDirectory(for: $0))
            }
            let hits = await Task.detached(priority: .userInitiated) {
                PlacemarkIndex.search(query, in: dirs)
            }.value
            if Task.isCancelled { return }
            placeHits = hits
        }
        // ⌘F (Search command) → focus the search field. Counter bump fires on every press.
        .onChange(of: appCommands.searchFocusRequested) { _, _ in
            isSearchFocused = true
        }
        // Reset a stale tag filter when its tag vanishes. MUST hang off the always-mounted
        // body, not `tagChipsBar` (which unmounts when the last tag goes — see HomeViewTags).
        .onChange(of: allTags) { _, tags in
            resetStaleTagFilter(tags)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    isFileImporterPresented = true
                } label: {
                    Label("Import", systemImage: "plus")
                }
                // While an import is in flight, the button is disabled and a progress
                // indicator (below) takes its visual place — re-tapping mid-import is a no-op
                // anyway (the picker just enqueues more), but the spinner signals work is on.
                // Also disabled while a duplicate alert stalls the queue: the coordinator is
                // waiting on the user's decision, so offering more imports would contradict
                // the stalled state (queued URLs are kept either way).
                .disabled(importCoordinator.isImporting || importCoordinator.pendingDuplicate != nil)
            }
            // Import progress: a spinner plus the current filename, shown only while the
            // coordinator is draining its queue (e.g. a large KMZ that takes a moment).
            // Placed in the bottom bar (`.bottomBar`) rather than `.principal`: a principal
            // item REPLACES the navigation title on compact width, which made the "Pinfold"
            // title vanish mid-import. The status bar floats below the list and leaves the
            // title intact on every size class.
            if importCoordinator.isImporting {
                ToolbarItem(placement: .bottomBar) {
                    HStack(spacing: 8) {
                        ProgressView()
                        if let name = importCoordinator.currentFilename {
                            Text("Importing \(name)…")
                                .font(.subheadline)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Text("Importing…")
                                .font(.subheadline)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            // Favorites — the consolidated, catalogue-wide starred-placemarks sheet. Leads the
            // trailing group (before sort/gear); shown on both segments since favorites span
            // every file, not just the current segment's.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isFavoritesPresented = true
                } label: {
                    Label("Favorites", systemImage: "star")
                }
            }
            // Sort menu — Files segment only (Trash keeps its trashed-date order). Sits next to
            // the gear in the trailing group rather than `.principal`, so it never replaces the
            // navigation title. The Picker drives `settings.entrySort`, which `sortedActive`
            // applies at render time (presentation-level; storage order is untouched).
            if segment == .files {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort By", selection: sortBinding) {
                            ForEach(EntrySort.allCases) { option in
                                Text(option.label).tag(option)
                            }
                        }
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isSettingsPresented = true
                } label: {
                    Label("Settings", systemImage: "gear")
                }
            }
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: allowedUTTypes,
            allowsMultipleSelection: true
        ) { result in
            handleFileImporterResult(result)
        }
        // Duplicate-import alert
        .alert(
            "Duplicate File",
            isPresented: Binding(
                get: { importCoordinator.pendingDuplicate != nil },
                // Route dismissal through skipDuplicate so the import queue always
                // advances, even if the alert is dismissed without tapping a button.
                // skipDuplicate is idempotent, so the button paths are unaffected.
                set: { if !$0 {
                    importCoordinator.skipDuplicate(
                        catalog: catalog, storage: catalog.storage, cache: resourceCache
                    )
                } }
            ),
            presenting: importCoordinator.pendingDuplicate
        ) { _ in
            Button("Import Anyway") {
                importCoordinator.importAnyway(
                    catalog: catalog,
                    storage: catalog.storage,
                    cache: resourceCache
                )
            }
            Button("Skip", role: .cancel) {
                importCoordinator.skipDuplicate(
                    catalog: catalog,
                    storage: catalog.storage,
                    cache: resourceCache
                )
            }
        } message: { dup in
            Text("\"\(dup.result.displayName)\" has already been imported. Would you like to import it again?")
        }
        // Import error alert
        .alert(
            "Import Failed",
            isPresented: Binding(
                get: { importCoordinator.importError != nil },
                set: { if !$0 { importCoordinator.importError = nil } }
            ),
            presenting: importCoordinator.importError
        ) { _ in
            Button("OK", role: .cancel) {
                importCoordinator.importError = nil
            }
        } message: { error in
            Text(error.localizedDescription)
        }
        // Rename alert — a single TextField prefilled with the current name. `presenting` keys
        // the alert to the entry being renamed; Save commits the trimmed name via
        // `catalog.rename` (which rejects an empty/whitespace name as a no-op).
        .alert(
            "Rename File",
            isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
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
        // `pendingDetailSearch` deep-link the catalogue "Places" search hits use.
        .sheet(isPresented: $isFavoritesPresented) {
            FavoritesView(selection: $selection, pendingDetailSearch: $pendingDetailSearch)
        }
        // The "Import…" menu command (⌘I) flips a counter on AppCommands; presenting the
        // fileImporter here keeps that transient UI state owned by the view, not the scene.
        .onChange(of: appCommands.importRequested) { _, _ in
            isFileImporterPresented = true
        }
        // Inbox draining (share-extension handoff) is performed once in RootView's
        // .task on launch; it is intentionally NOT duplicated here.
    }

    // MARK: - File list

    @ViewBuilder
    private var fileList: some View {
        if segment == .files {
            if isSearching {
                searchResults
            } else if active.isEmpty {
                ContentUnavailableView {
                    Label("No Files", systemImage: "map")
                } description: {
                    Text("Import a KML or KMZ file using the + button.")
                }
            } else {
                // `List(selection:)` drives the detail column on regular width and pushes the
                // detail on compact width (collapsed split view) — replacing the old explicit
                // `NavigationLink(destination:)`. Selection is by entry id (see `selection`).
                List(selection: $selection) {
                    ForEach(displayedActive) { entry in
                        FileRow(entry: entry)
                            .tag(entry.id)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    Task { await catalog.moveToTrash(entry) }
                                } label: {
                                    Label("Trash", systemImage: "trash")
                                }
                            }
                            .contextMenu { activeRowMenu(for: entry) }
                    }
                }
                .listStyle(.insetGrouped)
            }
        } else {
            if trashed.isEmpty {
                ContentUnavailableView {
                    Label("Trash is Empty", systemImage: "trash")
                } description: {
                    Text("Files you trash will appear here.")
                }
            } else {
                List {
                    ForEach(trashed) { entry in
                        FileRow(entry: entry)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    Task { await catalog.deleteForever(entry) }
                                } label: {
                                    Label("Delete", systemImage: "trash.fill")
                                }
                                Button {
                                    Task { await catalog.restore(entry) }
                                } label: {
                                    Label("Restore", systemImage: "arrow.uturn.backward")
                                }
                                .tint(.blue)
                            }
                            .contextMenu {
                                Button {
                                    Task { await catalog.restore(entry) }
                                } label: {
                                    Label("Restore", systemImage: "arrow.uturn.backward")
                                }
                                Button(role: .destructive) {
                                    Task { await catalog.deleteForever(entry) }
                                } label: {
                                    Label("Delete", systemImage: "trash.fill")
                                }
                            }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
    }

    /// A `Binding` to the persisted sort preference for the toolbar `Picker`. Built manually
    /// (rather than via `@Bindable`) so the `@Observable` `AppSettings` read from the
    /// environment can be bound without re-declaring it as a bindable property.
    private var sortBinding: Binding<EntrySort> {
        Binding(get: { settings.entrySort }, set: { settings.entrySort = $0 })
    }

    // MARK: - Picker bar

    /// Segmented Files / Trash picker, pinned directly below the navigation bar.
    private var pickerBar: some View {
        Picker("View", selection: $segment) {
            Text("Files").tag(Segment.files)
            if trashed.isEmpty {
                Text("Trash").tag(Segment.trash)
            } else {
                Text("Trash (\(trashed.count))").tag(Segment.trash)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    // MARK: - Import helpers

    private var allowedUTTypes: [UTType] {
        // Prefer UTType(filenameExtension:) for exact KML/KMZ match.
        // Fall back to .xml / .zip if the extension-derived type is unavailable.
        let kml = UTType(filenameExtension: "kml") ?? .xml
        let kmz = UTType(filenameExtension: "kmz") ?? .zip
        return [kml, kmz]
    }

    private func handleFileImporterResult(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            importCoordinator.enqueue(
                urls,
                catalog: catalog,
                storage: catalog.storage,
                cache: resourceCache
            )
        case let .failure(error):
            importCoordinator.importError = error
        }
    }
}
