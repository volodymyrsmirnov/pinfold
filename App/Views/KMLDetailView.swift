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

    // MARK: - Environment

    @Environment(\.storageLocations) private var storage

    // MARK: - State

    @State private var document: KMLDocument?
    @State private var loadError: Error?
    @State private var searchText = ""
    @State private var annotations: PlacemarkAnnotations?
    /// Collapsed folder ids (tree paths like "0/2"). Toggled by tapping a folder row;
    /// ignored while searching (the outline force-expands then).
    @State private var collapsedFolderIDs: Set<String> = []
    /// The memoized flattened outline, recomputed off-main (debounced for search-text
    /// changes) via the `.task(id:)` below. `nil` until the first build completes.
    @State private var outline: PlacemarkOutline?
    /// The query the current `outline` was built for. Used to tell a search-text change
    /// (debounce) from a collapse toggle (rebuild immediately) inside `rebuildOutline`.
    @State private var lastBuiltQuery = ""

    /// Debounce window for search-text changes before rebuilding the outline. Collapse
    /// toggles are not debounced (they compare equal query and skip the sleep).
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
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    if let document {
                        PlacemarkMapView(
                            placemarks: outline?.mappablePlacemarks ?? [],
                            document: document,
                            entry: entry
                        )
                        // A NavigationStack resolves a pushed destination's environment from
                        // the stack root, not from this (itself-pushed) view, so the
                        // `.environment(annotations)` on our body does not reach the map.
                        // Inject it directly on the destination.
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
            annotations = nil
            document = nil
            loadError = nil
            outline = nil
            lastBuiltQuery = ""
            collapsedFolderIDs = []
            await loadDocument()
        }
        // Recompute the flattened outline off-main when the document, query, or collapse
        // set changes. `.task(id:)` auto-cancels the in-flight build when the trigger
        // changes again, so rapid typing only keeps the latest. A ~250ms debounce is
        // applied only when the *query* changed (collapse toggles rebuild immediately).
        .task(id: OutlineTrigger(
            documentID: entry.id,
            documentLoaded: document != nil,
            query: searchText,
            collapsed: collapsedFolderIDs
        )) {
            await rebuildOutline()
        }
        .environment(annotations)
    }

    // MARK: - Outline rebuild

    /// Identity that drives the outline rebuild `.task`. Equatable so SwiftUI restarts the
    /// task only on a real change; carries enough to detect query-vs-collapse changes.
    private struct OutlineTrigger: Equatable {
        let documentID: CatalogEntry.ID
        /// Flips false→true when the parsed document finishes loading, so the first outline
        /// build fires then (the document is loaded asynchronously after first appearance).
        let documentLoaded: Bool
        let query: String
        let collapsed: Set<String>
    }

    /// Debounced, cancel-safe rebuild of `outline`. When the only thing that changed since
    /// the last build was the search text, waits `searchDebounce` first (coalescing
    /// keystrokes); collapse toggles skip the wait. The build itself runs in a detached
    /// task because `KMLContainer`/`KMLPlacemark` are `Sendable` value types.
    private func rebuildOutline() async {
        guard let document else { return }
        let query = searchText
        let collapsed = collapsedFolderIDs
        // Debounce only when the query changed; a collapse toggle leaves the query equal
        // to the last-built one, so it rebuilds immediately.
        if query != lastBuiltQuery {
            try? await Task.sleep(for: Self.searchDebounce)
            if Task.isCancelled { return }
        }
        let root = document.root
        let built = await Task.detached(priority: .userInitiated) {
            PlacemarkOutline.build(from: root, matching: query, collapsed: collapsed)
        }.value
        if Task.isCancelled { return }
        outline = built
        lastBuiltQuery = query
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
                            outlineRow(row, document: document)
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
    private func outlineRow(_ row: PlacemarkOutline.Row, document: KMLDocument) -> some View {
        switch row.kind {
        case let .folder(name, id):
            folderRow(name: name, id: id)
                .listRowInsets(EdgeInsets(top: 6, leading: leadingInset(row.depth), bottom: 6, trailing: 16))
        case let .placemark(placemark):
            placemarkLink(placemark, document: document)
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

    private func placemarkLink(_ placemark: KMLPlacemark, document: KMLDocument) -> some View {
        NavigationLink(destination: PlacemarkDetailView(
            placemark: placemark,
            document: document,
            entry: entry
        )
        // Inject the store directly on the destination: a pushed view does not inherit
        // the `.environment(annotations)` applied within this view's body (the stack
        // resolves a destination's environment from the stack root).
        .environment(annotations)) {
            PlacemarkRow(placemark: placemark, document: document, entry: entry)
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
