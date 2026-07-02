import CoreLocation
import PinfoldCore
import SwiftUI

// MARK: - KMLDetailView

/// Displays the folder/placemark hierarchy of a single imported KML/KMZ file.
///
/// On appearance the original file is loaded and parsed off the main actor. While
/// loading a `ProgressView` is shown; on error a `ContentUnavailableView` is shown.
///
/// A search field is rendered as the first (non-sticky) row of the list, styled like
/// the other groups. Typing in it filters the hierarchy in place — folders that contain
/// matches stay, the rest are pruned — so results remain grouped by category. Because the
/// search field lives in the list (not the navigation bar's search mode), the back and
/// map toolbar buttons stay visible while searching, and the map plots the filtered set.
struct KMLDetailView: View {
    // MARK: - Properties

    let entry: CatalogEntry

    /// A one-shot navigation payload: routes to push (and, for session restore, the
    /// transient list state to seed) once the document is parsed. Supplied by `RootView` for
    /// deep links (a single `.placemark` route) and session restore (the saved stack).
    /// `nil` for a normal selection. Consumed once via `onConsumeRestore` (then the owner
    /// clears its one-shot source so re-selecting the file normally doesn't re-push).
    var initialRestore: RestoreBundle?

    /// Called once after `initialRestore` has been consumed, so the owner can clear its
    /// one-shot source. Defaults to a no-op for callers that don't plumb it.
    var onConsumeRestore: () -> Void = {}

    // MARK: - Environment

    @Environment(\.storageLocations) private var storage
    @Environment(NavigationRouter.self) private var router: NavigationRouter?
    @Environment(AppSettings.self) private var settings: AppSettings?
    @Environment(\.scenePhase) private var scenePhase

    // MARK: - State

    @State private var document: KMLDocument?
    /// The entry id whose `document` is currently loaded. Guards the appearance-bound load `.task`
    /// so it reloads only for a genuinely new entry — NOT when this view merely re-appears after a
    /// pushed `PlacemarkDetailView` is popped. Reloading on return would nil `document`/`outline`,
    /// swap the list for the loading view, and lose the scroll position. See the `.task(id:)`.
    @State private var loadedEntryID: CatalogEntry.ID?
    @State private var loadError: Error?
    @State private var searchText = ""
    @State private var annotations: PlacemarkAnnotations?
    /// Collapsed folder ids (tree paths like "0/2"). Toggled by tapping a folder row;
    /// ignored while searching (the outline force-expands then).
    @State private var collapsedFolderIDs: Set<String> = []
    /// The memoized flattened outline, recomputed off-main via the two `.task(id:)`
    /// modifiers below. `nil` until the first build completes.
    @State private var outline: PlacemarkOutline?
    /// One-shot location provider for distance display and the nearest-first sort. Requests a
    /// fix when the view appears; `lastLocation` is nil until it arrives / when denied.
    @State private var locationAuth = LocationAuthorization()
    /// Whether the outline sorts placemarks nearest-first (flat, folders dropped) instead of in
    /// document order. Only takes effect once a location fix is known; see `effectiveSort`.
    @State private var nearestFirst = false

    /// The outline row id to scroll to once rows are built — a one-shot from session
    /// restore, consumed by the verified-retry scroll task (see `applyPendingScroll`).
    @State private var pendingScrollRowID: String?

    /// Live row geometry for scroll-anchor capture/restore. A plain class (not @Observable):
    /// per-frame writes must not invalidate the view tree. See `RowFrameBox`.
    @State private var rowFrames = RowFrameBox()

    /// Debounce window for search-text changes before rebuilding the outline. Collapse
    /// toggles and document loads are not debounced (they go through a separate trigger).
    private static let searchDebounce: Duration = .milliseconds(250)

    // MARK: - Body

    var body: some View {
        Group {
            if let error = loadError {
                ContentUnavailableView {
                    Label("Cannot Open File", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error.localizedDescription)
                }
            } else if let document {
                contentList(document)
            } else {
                ProgressView("Loading\u{2026}")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(entry.displayName)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            // Sort menu: Document order vs. Nearest first. "Nearest" is disabled until a
            // location fix is known (so the user isn't offered a sort that can't be applied).
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $nearestFirst) {
                        Label("Document Order", systemImage: "list.bullet").tag(false)
                        Label("Nearest First", systemImage: "location").tag(true)
                    }
                    .disabled(locationAuth.lastLocation == nil)
                } label: {
                    Image(systemName: nearestFirst ? "location.fill" : "arrow.up.arrow.down")
                }
                .accessibilityLabel("Sort")
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: EntryRoute.map(focusKey: nil)) {
                    Image(systemName: "map")
                }
                .accessibilityLabel("Map")
                .disabled((outline?.mappablePlacemarks.isEmpty ?? true))
            }
        }
        .task(id: entry.id) {
            // `.task` is appearance-bound: pushing `PlacemarkDetailView` makes this view disappear,
            // and popping back re-runs this task even though `entry.id` is unchanged. Loading is
            // idempotent per entry so a RETURN does not nil `document`/`outline` (which would swap
            // the list for the loading view, destroying its scroll position and re-parsing the
            // file). Only a genuinely new entry — or a prior load cancelled before `document`
            // arrived (a mid-load push) — falls through to reload.
            if loadedEntryID == entry.id, document != nil { return }
            loadedEntryID = entry.id
            annotations = nil
            document = nil
            loadError = nil
            outline = nil
            collapsedFolderIDs = []
            nearestFirst = false
            searchText = ""
            // Ask for a one-shot location fix so distances and the nearest sort can light up.
            locationAuth.request()
            await loadDocument()
            // One-shot navigation payload: seed the transient list state (session restore
            // only — a deep link must not clobber it), validate the saved routes against the
            // freshly parsed document, and set the stack. Seeding happens BEFORE the
            // immediate outline trigger fires, so the first outline is built once, in the
            // right shape. Consume whether or not routes resolved, so a stale payload
            // doesn't leak into another file.
            applyInitialRestore()
        }
        // Second consume path: a deep link into the file that is ALREADY open. The view
        // keeps its identity (`.id(entry.id)` unchanged) so the load `.task` does NOT
        // refire — but SwiftUI re-evaluates the body with the new `initialRestore` param,
        // and this `.onChange` observes the nil→bundle transition and pushes against the
        // already-loaded document. Routes only — never the transient list state (this path
        // is only reachable for deep links; restore bundles arrive with a fresh identity).
        // The `let document` guard covers the mid-load race: not ready yet → no-op WITHOUT
        // consuming; the in-flight load task applies it instead.
        .onChange(of: initialRestore) { _, newValue in
            guard let newValue, !newValue.routes.isEmpty, let document else { return }
            let valid = EntryRoute.validatedForRestore(newValue.routes) {
                document.root.firstPlacemark(withStableKey: $0) != nil
            }
            guard !valid.isEmpty else { return }
            router?.path.append(contentsOf: valid)
            onConsumeRestore()
        }
        // The per-file half of the resume snapshot (RootView writes selection + routes on
        // the same transition). `.inactive` always precedes backgrounding, BEFORE iOS's
        // snapshot passes can re-lay the list out under us.
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .inactive else { return }
            saveResumeSlice()
        }
        // The outline rebuild is driven by TWO independent triggers so the debounce policy
        // derives from *which trigger fired*, never from mutable post-build state (a single
        // task comparing against a "last built query" could mis-debounce a collapse toggle
        // that restarted it mid-sleep):
        // - Query trigger: keyed on the search text alone; sleeps ~250ms first, coalescing
        //   keystrokes (`.task(id:)` auto-cancels superseded runs).
        // - Immediate trigger: keyed on entry, document-loaded flag, and collapse set;
        //   rebuilds with no debounce (collapse toggles and the initial document load must
        //   feel instant).
        // Both funnel into `buildOutlineNow()`, which snapshots the live state when it runs.
        .task(id: searchText) {
            try? await Task.sleep(for: Self.searchDebounce)
            if Task.isCancelled { return }
            await buildOutlineNow()
        }
        .task(id: ImmediateOutlineTrigger(
            documentID: entry.id,
            documentLoaded: document != nil,
            collapsed: collapsedFolderIDs,
            nearestFirst: nearestFirst,
            // A new fix (or the first one) must rebuild a nearest-first outline so the order
            // reflects the user's current position. Identity by coordinate keeps it cheap.
            locationLat: locationAuth.lastLocation?.coordinate.latitude,
            locationLon: locationAuth.lastLocation?.coordinate.longitude
        )) {
            await buildOutlineNow()
        }
        // THE destination table: every EntryRoute pushed anywhere in this file's stack —
        // list rows, the toolbar map, the POI page's "Show on Map", the map's preview card,
        // deep links, session restore — resolves here, the one place that has the parsed
        // `document`, `outline`, and `annotations`. Registered on the stack root's content,
        // so pushed views need no registration of their own. Re-injecting `annotations` is
        // needed ONCE here (a pushed destination resolves its environment from the stack
        // root, not from this view's body-level injection below).
        .navigationDestination(for: EntryRoute.self) { route in
            destinationView(for: route)
        }
        // This injection reaches this view's OWN body uses (the search/context swipe favorite &
        // visited actions and the in-list `PlacemarkRow` strikethrough) — but NOT destinations
        // pushed onto the stack. KMLDetailView is the stack's root *content*, not the stack
        // itself (the NavigationStack lives in RootView); a pushed destination resolves its
        // environment from the stack, so content-level injection here is dropped for the map and
        // the placemark detail. The destination table re-injects `annotations` once instead.
        .environment(annotations)
    }

    /// Applies the one-shot `initialRestore` payload against the freshly loaded document.
    /// See the load `.task` for sequencing; kept out of the closure to keep its SIL small.
    private func applyInitialRestore() {
        guard let initialRestore, let document else {
            if initialRestore != nil { onConsumeRestore() }
            return
        }
        if initialRestore.entryFolderName != nil {
            // Session restore: seed the saved transient state. (Deep-link bundles have a
            // nil folder name and leave the fresh defaults alone.)
            searchText = initialRestore.searchText
            collapsedFolderIDs = initialRestore.collapsedFolderIDs
            nearestFirst = initialRestore.nearestFirst
            pendingScrollRowID = initialRestore.scrollAnchorRowID
        }
        let valid = EntryRoute.validatedForRestore(initialRestore.routes) {
            document.root.firstPlacemark(withStableKey: $0) != nil
        }
        router?.path = valid
        onConsumeRestore()
    }

    /// Writes the transient list state + scroll anchor to the resume slice. The scroll
    /// anchor is computed from live row geometry (Task 7 wires `rowFrames`; until then
    /// `anchorRowID()` returns nil and only the transient state is saved).
    private func saveResumeSlice() {
        guard let settings, settings.restoreSessionEnabled, document != nil else { return }
        settings.resumeSearchText = searchText
        settings.resumeCollapsedFolderIDs = Array(collapsedFolderIDs)
        settings.resumeNearestFirst = nearestFirst
        settings.resumeScrollAnchorRowID = rowFrames.anchorRowID()
    }

    /// Resolves a pushed route into its screen. A `.placemark` whose stableKey no longer
    /// resolves renders empty — unreachable in practice (routes are validated before
    /// pushing) but a safe no-op if the document changes under an open stack.
    @ViewBuilder
    private func destinationView(for route: EntryRoute) -> some View {
        if let document {
            switch route {
            case let .placemark(stableKey):
                if let match = document.root.firstPlacemark(withStableKey: stableKey) {
                    PlacemarkDetailView(placemark: match, document: document, entry: entry)
                        .environment(annotations)
                }
            case let .map(focusKey):
                PlacemarkMapView(
                    // "Show on Map" (focusKey != nil) plots EVERY coordinate-bearing
                    // placemark (the POI page has no search context); the toolbar/restored
                    // map (focusKey == nil) plots the live filtered outline — both exactly
                    // as before the route refactor.
                    placemarks: focusKey != nil
                        ? document.root.allPlacemarks.filter { $0.coordinate != nil }
                        : (outline?.mappablePlacemarks ?? []),
                    document: document,
                    entry: entry,
                    initialFocusKey: focusKey
                )
                .environment(annotations)
            }
        }
    }

    // MARK: - Outline rebuild

    /// Identity for the un-debounced outline rebuild `.task`: the document (id + loaded
    /// flag, since the document arrives asynchronously after first appearance) and the
    /// collapse set. The search text deliberately lives in its own debounced trigger.
    private struct ImmediateOutlineTrigger: Equatable {
        let documentID: CatalogEntry.ID
        let documentLoaded: Bool
        let collapsed: Set<String>
        let nearestFirst: Bool
        let locationLat: Double?
        let locationLon: Double?
    }

    /// The sort to build the outline with: `.nearest` only when the user chose it AND a location
    /// fix is available; otherwise `.document`. Computed on the main actor (reads `locationAuth`)
    /// and passed into the detached build, which takes a plain `Sendable` value.
    private var effectiveSort: PlacemarkOutline.Sort {
        if nearestFirst, let location = locationAuth.lastLocation {
            return .nearest(location)
        }
        return .document
    }

    /// Rebuilds `outline` from the live `searchText`/`collapsedFolderIDs` immediately
    /// (debouncing is the caller's concern). Cancel-safe: the result is discarded if the
    /// owning `.task` was superseded. The walk runs in a detached task because
    /// `KMLContainer`/`KMLPlacemark` are `Sendable` value types.
    private func buildOutlineNow() async {
        guard let document else { return }
        let query = searchText
        let collapsed = collapsedFolderIDs
        let root = document.root
        let sort = effectiveSort
        let built = await Task.detached(priority: .userInitiated) {
            PlacemarkOutline.build(from: root, matching: query, collapsed: collapsed, sort: sort)
        }.value
        if Task.isCancelled { return }
        outline = built
    }

    // MARK: - Load document

    private func loadDocument() async {
        annotations = PlacemarkAnnotations(entry: entry, storage: storage)
        let fileURL = storage.originalFile(for: entry)
        do {
            let parsedKML = try await Task.detached(priority: .userInitiated) {
                // Materialize the original from iCloud first if it is a not-yet-downloaded
                // placeholder (no-op for local files). Off-main; a spinner shows meanwhile.
                let data = try UbiquityContainer.readDownloadingIfNeeded(fileURL)
                return try KMLReader.read(data: data)
            }.value
            document = parsedKML.document
        } catch {
            loadError = error
        }
    }

    // MARK: - Content list

    /// A single inset-grouped list: the search field row, then the flattened placemark
    /// outline. Rendering a flat `[PlacemarkOutline.Row]` (instead of nested `Section`/
    /// `DisclosureGroup` trees built via `AnyView`) lets `List` lazily realize and diff
    /// rows, and confines per-keystroke work to one memoized, debounced tree walk.
    @ViewBuilder
    private func contentList(_ document: KMLDocument) -> some View {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        // Snapshot the user's location ONCE per list build so every row shares one fix instead
        // of re-reading `locationAuth` per row. `nil` → rows show no distance.
        let location = locationAuth.lastLocation
        List {
            searchSection
            if let outline {
                if outline.rows.isEmpty, !query.isEmpty {
                    Section {
                        Text("No placemarks match \u{201C}\(query)\u{201D}.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                } else {
                    Section {
                        ForEach(outline.rows) { row in
                            outlineRow(row, document: document, location: location)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Outline row

    /// Renders a single flattened outline row by kind, indented by its depth. Folder rows
    /// toggle their membership in `collapsedFolderIDs` (and rotate a chevron like a
    /// `DisclosureGroup`); while searching the outline ignores that set, so the chevron is
    /// shown expanded and tapping it has no visible effect until the query is cleared.
    @ViewBuilder
    private func outlineRow(
        _ row: PlacemarkOutline.Row, document: KMLDocument, location: CLLocation?
    ) -> some View {
        switch row.kind {
        case let .folder(name, id):
            folderRow(name: name, id: id)
                .listRowInsets(EdgeInsets(top: 6, leading: leadingInset(row.depth), bottom: 6, trailing: 16))
        case let .placemark(placemark):
            placemarkLink(placemark, document: document, location: location)
                .listRowInsets(EdgeInsets(top: 6, leading: leadingInset(row.depth), bottom: 6, trailing: 16))
        }
    }

    /// Base list-row leading inset plus the per-depth indent.
    private func leadingInset(_ depth: Int) -> CGFloat {
        16 + CGFloat(depth) * 16
    }

    /// A tappable folder header row with a disclosure chevron that rotates with the
    /// collapsed state. A non-empty search ignores the collapsed set, so the chevron is
    /// pinned open while searching.
    private func folderRow(name: String, id: String) -> some View {
        let searching = !searchText.trimmingCharacters(in: .whitespaces).isEmpty
        let collapsed = !searching && collapsedFolderIDs.contains(id)
        return Button {
            if collapsedFolderIDs.contains(id) {
                collapsedFolderIDs.remove(id)
            } else {
                collapsedFolderIDs.insert(id)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    // Purely decorative; the Button's label/value/hint carry the semantics.
                    .accessibilityHidden(true)
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(searching)
        .accessibilityLabel(name)
        .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
        // String literal resolves as a LocalizedStringKey, so it localizes like Text.
        .accessibilityHint("Expands or collapses this folder.")
    }

    // MARK: - Search field row

    /// The search field, rendered as the first list group with the same card styling as
    /// the others. It scrolls with the content (non-sticky) and never enters the navigation
    /// bar's search mode, so the back and map buttons stay visible while searching.
    private var searchSection: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search placemarks", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
        }
    }

    // MARK: - Placemark navigation link

    /// Known accepted edge: two occurrences of the same POI share a `stableKey` (it hashes
    /// `name|lat|lon`), so both rows now push the FIRST occurrence's page — the same
    /// first-match semantics every existing deep link (Spotlight, favorites) already has.
    private func placemarkLink(
        _ placemark: KMLPlacemark, document: KMLDocument, location: CLLocation?
    ) -> some View {
        NavigationLink(value: EntryRoute.placemark(stableKey: placemark.stableKey)) {
            PlacemarkRow(
                placemark: placemark,
                document: document,
                entry: entry,
                distance: PlacemarkDistance.format(from: location, to: placemark.coordinate)
            )
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if let annotations {
                Button {
                    annotations.toggleFavorite(placemark)
                } label: {
                    let on = annotations.isFavorite(placemark)
                    Label(on ? "Unfavorite" : "Favorite", systemImage: on ? "star.slash" : "star")
                }
                .tint(.yellow)

                Button {
                    annotations.toggleVisited(placemark)
                } label: {
                    let on = annotations.isVisited(placemark)
                    Label(on ? "Mark Unseen" : "Mark Seen", systemImage: on ? "eye.slash" : "eye")
                }
                .tint(.blue)
            }
        }
        .contextMenu {
            if let annotations {
                Button {
                    annotations.toggleFavorite(placemark)
                } label: {
                    let on = annotations.isFavorite(placemark)
                    Label(on ? "Unfavorite" : "Favorite", systemImage: on ? "star.slash" : "star")
                }

                Button {
                    annotations.toggleVisited(placemark)
                } label: {
                    let on = annotations.isVisited(placemark)
                    Label(on ? "Mark Unseen" : "Mark Seen", systemImage: on ? "eye.slash" : "eye")
                }
            }
        }
    }
}
