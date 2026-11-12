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

    @Environment(\.storageLocations) var storage
    @Environment(NavigationRouter.self) var router: NavigationRouter?
    @Environment(AppSettings.self) var settings: AppSettings?
    @Environment(\.scenePhase) var scenePhase

    // MARK: - State

    @State var document: KMLDocument?
    /// The entry id whose `document` is currently loaded. Guards the appearance-bound load `.task`
    /// so it reloads only for a genuinely new entry — NOT when this view merely re-appears after a
    /// pushed `PlacemarkDetailView` is popped. Reloading on return would nil `document`/`outline`,
    /// swap the list for the loading view, and lose the scroll position. See the `.task(id:)`.
    @State var loadedEntryID: CatalogEntry.ID?
    @State var loadError: Error?
    @State var searchText = ""
    @State var annotations: PlacemarkAnnotations?
    /// Collapsed folder ids (tree paths like "0/2"). Toggled by tapping a folder row;
    /// ignored while searching (the outline force-expands then).
    @State var collapsedFolderIDs: Set<String> = []
    /// The memoized flattened outline, recomputed off-main via the two `.task(id:)`
    /// modifiers below. `nil` until the first build completes.
    @State var outline: PlacemarkOutline?
    /// Monotonic count of completed outline rebuilds. The scroll-restore task keys on THIS
    /// (not `outline?.rows.count`): a rebuild can reorder rows without changing their count
    /// — e.g. the nearest-first re-sort arriving on a flat, folderless file — and a
    /// count-keyed id would silently never re-fire the pending-anchor retry.
    @State var outlineGeneration = 0
    /// One-shot location provider for distance display and the nearest-first sort. Requests a
    /// fix when the view appears; `lastLocation` is nil until it arrives / when denied.
    @State var locationAuth = LocationAuthorization()
    /// Whether the outline sorts placemarks nearest-first (flat, folders dropped) instead of in
    /// document order. Only takes effect once a location fix is known; see `effectiveSort`.
    @State var nearestFirst = false

    /// The outline row id to scroll to once rows are built — a one-shot from session
    /// restore, consumed by the verified-retry scroll task (see `applyPendingScroll`).
    @State var pendingScrollRowID: String?

    /// Live row geometry for scroll-anchor capture/restore. A plain class (not @Observable):
    /// per-frame writes must not invalidate the view tree. See `RowFrameBox`.
    @State var rowFrames = RowFrameBox()

    /// Debounce window for search-text changes before rebuilding the outline. Collapse
    /// toggles and document loads are not debounced (they go through a separate trigger).
    static let searchDebounce: Duration = .milliseconds(250)

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
            if loadedEntryID == entry.id, document != nil {
                return
            }
            loadedEntryID = entry.id
            annotations = nil
            document = nil
            loadError = nil
            outline = nil
            collapsedFolderIDs = []
            nearestFirst = false
            searchText = ""
            pendingScrollRowID = nil
            rowFrames.reset()
            // Ask for a one-shot location fix so distances and the nearest sort can light up.
            locationAuth.request()
            await loadDocument()
            // The detached parse doesn't observe this task's cancellation, so a reselect
            // mid-parse lets this continuation run to completion. Bail before touching the
            // SHARED router path — a zombie load for one file must not set its routes on
            // another file's stack (pre-refactor this wrote harmless view-local state; the
            // shared router made it cross-file).
            if Task.isCancelled {
                return
            }
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
        // The `let document` guard covers the mid-load race: not ready yet → no-op
        // WITHOUT consuming. (A bundle arriving mid-load is dropped once the load finishes —
        // the running task captured the pre-arrival view value — matching the pre-refactor
        // behavior; the next selection change clears the stale one-shot.)
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
            if Task.isCancelled {
                return
            }
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
}
