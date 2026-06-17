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

    /// A one-shot deep-link target: the durable `stableKey` of the placemark to open, supplied
    /// when this file was opened from a catalogue-wide hit (a "Places" search result, a favorite,
    /// or a Spotlight result — see `HomeView`/`FavoritesView`/`RootView`). After the document is
    /// parsed, the key is resolved to a `KMLPlacemark` and `PlacemarkDetailView` is pushed.
    /// `nil` for a normal selection. Consumed once (then `onConsumePlacemarkKey` clears the
    /// source so re-selecting the file normally doesn't re-push).
    var initialPlacemarkKey: String?

    /// Called once after `initialPlacemarkKey` has been consumed, so the owner can clear its
    /// one-shot source. Defaults to a no-op for callers (e.g. previews) that don't plumb it.
    var onConsumePlacemarkKey: () -> Void = {}

    // MARK: - Environment

    @Environment(\.storageLocations) private var storage

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

    /// The placemark a deep link resolved to, driving a programmatic push of
    /// `PlacemarkDetailView` via `.navigationDestination(item:)`. `nil` when no deep link is
    /// active. Set by the load `.task` (new file) or `.onChange(of: initialPlacemarkKey)`
    /// (file already open).
    @State private var deepLinkTarget: PlacemarkRoute?

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
                NavigationLink {
                    if let document {
                        // Re-inject `annotations`: this map is pushed from KMLDetailView, which
                        // is itself a pushed view, so the destination is hosted by the ancestor
                        // NavigationStack and resolves its environment from the STACK ROOT — not
                        // from the `.environment(annotations)` applied to this view's body below.
                        // Without this, `annotations` is nil in the map, so favorite/visited
                        // decoration (faded Seen pins, favorite stars) and the preview card's
                        // Seen styling silently no-op. Same exception as PlacemarkMapView's own
                        // onward push and the POI page's "Show on Map".
                        PlacemarkMapView(
                            placemarks: outline?.mappablePlacemarks ?? [],
                            document: document,
                            entry: entry
                        )
                        .environment(annotations)
                    }
                } label: {
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
            deepLinkTarget = nil
            // Ask for a one-shot location fix so distances and the nearest sort can light up.
            locationAuth.request()
            await loadDocument()
            // Deep link: if this file was opened from a placemark hit, resolve the carried
            // stableKey against the freshly-parsed document and push its detail page. Consume
            // the one-shot key (whether or not it resolved) so a later normal re-selection of
            // the same file doesn't re-push, and so a stale key doesn't leak into another file.
            if let initialPlacemarkKey, !initialPlacemarkKey.isEmpty, let document,
               let match = document.root.firstPlacemark(withStableKey: initialPlacemarkKey)
            {
                deepLinkTarget = PlacemarkRoute(placemark: match)
            }
            if initialPlacemarkKey != nil {
                onConsumePlacemarkKey()
            }
        }
        // Second consume path: a deep link into the file that is ALREADY open. The view keeps
        // its identity (`.id(entry.id)` unchanged), so the load `.task` above does NOT refire —
        // but SwiftUI re-evaluates the body with the new `initialPlacemarkKey` param, and this
        // `.onChange` observes the nil→key transition and pushes against the already-loaded
        // document. The guard's `let document` also covers the rare mid-load race: if the
        // document isn't ready yet, this no-ops WITHOUT consuming, and the in-flight load `.task`
        // (which reads `initialPlacemarkKey` after `loadDocument()`) handles it instead.
        .onChange(of: initialPlacemarkKey) { _, newValue in
            guard let newValue, !newValue.isEmpty, let document,
                  let match = document.root.firstPlacemark(withStableKey: newValue) else { return }
            deepLinkTarget = PlacemarkRoute(placemark: match)
            onConsumePlacemarkKey()
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
        // Programmatic push for a resolved deep link. `deepLinkTarget` is only set once the
        // document is loaded, so `if let document` always succeeds here. Lives on the detail
        // column's NavigationStack root (this view), so the push lands in the detail column and
        // inherits the `.environment(annotations)` injected just below — the same environment
        // the list's own `NavigationLink`s rely on.
        .navigationDestination(item: $deepLinkTarget) { route in
            if let document {
                // Re-inject `annotations` for the same reason as the list-row push below: a
                // destination pushed onto the ancestor NavigationStack resolves its environment
                // from the stack root, not from this view's body-level injection.
                PlacemarkDetailView(placemark: route.placemark, document: document, entry: entry)
                    .environment(annotations)
            }
        }
        // This injection reaches this view's OWN body uses (the search/context swipe favorite &
        // visited actions and the in-list `PlacemarkRow` strikethrough) — but NOT destinations
        // pushed onto the stack. KMLDetailView is the stack's root *content*, not the stack
        // itself (the NavigationStack lives in RootView); a pushed destination resolves its
        // environment from the stack, so content-level injection here is dropped for the map and
        // the placemark detail. Each push site therefore re-injects `annotations` explicitly
        // (the list row, the deep-link destination, the toolbar map, and the POI page's
        // "Show on Map") — matching how RootView injects the shared service bundle on the stack.
        .environment(annotations)
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

    /// Identifies a programmatic push target by the placemark's parse-`id`, which is unique
    /// within a single loaded document (the only scope this route lives in). A wrapper exists
    /// because `KMLPlacemark` is `Equatable`/`Identifiable` but not `Hashable`, which
    /// `.navigationDestination(item:)` requires.
    private struct PlacemarkRoute: Identifiable, Hashable {
        let placemark: KMLPlacemark
        var id: String {
            placemark.id
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.placemark.id == rhs.placemark.id
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(placemark.id)
        }
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

    private func placemarkLink(
        _ placemark: KMLPlacemark, document: KMLDocument, location: CLLocation?
    ) -> some View {
        NavigationLink(destination: PlacemarkDetailView(
            placemark: placemark,
            document: document,
            entry: entry
        )
        // Re-inject `annotations`: the pushed detail page is hosted by the ancestor
        // NavigationStack and resolves its environment from the stack root, not from the
        // `.environment(annotations)` this view applies to its own body. Without this the
        // detail page's `annotations` is nil — its Favorite/Seen menu items vanish and its
        // "Show on Map" forwards nil, so map pins lose favorite/visited decoration.
        .environment(annotations)) {
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
