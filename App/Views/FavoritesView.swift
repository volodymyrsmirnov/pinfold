import SwiftUI

// MARK: - FavoritesView

/// A consolidated, catalogue-wide view of every starred placemark across all files — the
/// "all my favorites" screen Pinfold otherwise lacks (favorites are stored per-file in each
/// entry's synced sidecar, with no single place to see them together).
///
/// Presented as a sheet from `HomeView`'s star toolbar button. One section per file (in
/// catalogue order, active entries with non-empty `favoriteKeys` only); rows are the
/// resolved favorite placemark names (plus a coordinate subtitle when present). Tapping a row
/// deep-links into that file's outline using the SAME consume-once mechanism as a "Places"
/// search hit: it sets `pendingDetailSearch` to the placemark name and selects the entry (see
/// `HomeSearchResults.openPlaceHit`). The sheet dismisses first so the selection lands on the
/// underlying split view.
///
/// Data is loaded off-main on appear: for each active entry the favorite keys come from its
/// sidecar (coordinated I/O, fine off-main) and resolve against the entry's local
/// `placemarks-index.json` via `PlacemarkIndex.resolve`. An entry whose index hasn't been
/// materialized yet contributes nothing; if favorites exist but NOTHING resolves, a footnote
/// row explains they'll appear once their files finish processing.
struct FavoritesView: View {
    // MARK: - Bindings (mirror how HomeSearchResults drives the deep-link)

    /// The catalogue selection, owned by `RootView`. Set to the favorite's entry id to open it.
    @Binding var selection: CatalogEntry.ID?

    /// One-shot deep-link search string, owned by `RootView`. Set to the tapped favorite's name
    /// so the opened file's outline pre-filters to that placemark. See `RootView`.
    @Binding var pendingDetailSearch: String?

    // MARK: - Environment

    @Environment(Catalog.self) private var catalog
    @Environment(\.storageLocations) private var storage
    @Environment(\.dismiss) private var dismiss

    // MARK: - Loaded state

    /// One file's resolved favorites: the entry plus its starred placemarks, sorted by name.
    fileprivate struct FavoriteGroup: Identifiable {
        let entry: CatalogEntry
        let hits: [PlacemarkIndex.Hit]
        var id: CatalogEntry.ID {
            entry.id
        }
    }

    /// `nil` until the first off-main load completes (drives the loading state vs. empty state).
    @State private var groups: [FavoriteGroup]?
    /// `true` when at least one active entry has favorites but none resolved yet (their indexes
    /// aren't materialized). Drives the "will appear after processing" footnote.
    @State private var hasUnresolvedFavorites = false

    // MARK: - Body

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Favorites")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        // Re-load whenever the active catalogue identity set changes. The id is computed in a
        // helper (not an inline `.map` closure) to keep `body`'s SIL free of an extra closure.
        .task(id: activeEntryIDs) {
            await load()
        }
    }

    /// The active entries' ids, the `.task` identity (re-loads when the catalogue set changes).
    private var activeEntryIDs: [CatalogEntry.ID] {
        catalog.active.map(\.id)
    }

    /// The view body is split into small, explicitly-typed helpers (`emptyState`, `favoritesList`,
    /// `loading`) rather than one deeply-nested `@ViewBuilder`: nesting `List`/`ForEach`/`Section`/
    /// `Button` under conditionals makes SwiftUI's type-checker pathologically slow, so each piece
    /// returns a concrete `some View` to keep inference cheap.
    @ViewBuilder
    private var content: some View {
        if let groups {
            if groups.isEmpty, !hasUnresolvedFavorites {
                emptyState
            } else {
                // The list lives in its own `View` struct so this file's view methods stay small.
                // Bundling the full `List`/`ForEach`/`Section`/`Button` tree into one big `body`
                // here tripped a SIL `ClosureLifetimeFixup` blow-up (minutes-long compile).
                FavoritesList(groups: groups, hasUnresolved: hasUnresolvedFavorites, onTap: open)
            }
        } else {
            loading
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Favorites", systemImage: "star")
        } description: {
            Text("Star a placemark in a file to collect it here.")
        }
    }

    private var loading: some View {
        ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    /// Deep-links into the favorite's file, mirroring `HomeSearchResults.openPlaceHit`: seed the
    /// one-shot outline filter with the placemark name, then select the entry. The sheet is
    /// dismissed FIRST so the selection change reaches the underlying split view — driving the
    /// detail column to the favorite's file (and its pre-filtered outline).
    private func open(_ hit: PlacemarkIndex.Hit) {
        guard let entry = catalog.active.first(where: { $0.storageFolderName == hit.folderName }) else { return }
        dismiss()
        pendingDetailSearch = hit.name.isEmpty ? nil : hit.name
        selection = entry.id
    }

    // MARK: - Load

    /// A per-entry snapshot handed to the off-main load: the entry plus the on-disk locations
    /// its favorites are read from. `Sendable` so it can cross into the detached load.
    fileprivate struct LoadInput {
        let entry: CatalogEntry
        let folderName: String
        let resourcesDir: URL
    }

    /// The result of the off-main load: the per-file groups plus whether any favorites are still
    /// unresolved (their indexes not yet materialized).
    fileprivate struct LoadResult {
        let groups: [FavoriteGroup]
        let hasUnresolved: Bool
    }

    /// Off-main load: read each active entry's favorite keys from its sidecar and resolve them
    /// against its local index. Groups follow catalogue order; entries with no favorites (or no
    /// resolvable favorites) are dropped from the sections, but the presence of unresolved
    /// favorites is tracked so the footnote can explain the gap.
    private func load() async {
        // Snapshot the per-entry inputs on the main actor (Catalog + StorageLocations are
        // @MainActor / value types), then hand them to a `nonisolated` async free function that
        // owns the off-main detach. Keeping the `Task.detached { … }` closure OUT of this
        // `@MainActor async` method avoids a SIL `ClosureLifetimeFixup` blow-up (dominance
        // analysis over the captured-closure graph) that otherwise makes this file take minutes
        // to compile.
        let inputs = snapshotInputs()
        let result = await loadFavorites(inputs, storage: storage)
        guard !Task.isCancelled else { return }
        groups = result.groups
        hasUnresolvedFavorites = result.hasUnresolved
    }

    /// Builds the per-entry load inputs from the active catalogue (main-actor read).
    private func snapshotInputs() -> [LoadInput] {
        catalog.active.map {
            LoadInput(
                entry: $0,
                folderName: $0.storageFolderName,
                resourcesDir: storage.resourcesDirectory(for: $0)
            )
        }
    }
}

// MARK: - Off-main load

/// Runs `resolveFavorites` off the main actor and returns its result. A `nonisolated` async
/// free function so the `Task.detached` closure is compiled here, not inside the view's
/// `@MainActor` `load()` — see `FavoritesView.load()`.
private func loadFavorites(
    _ inputs: [FavoritesView.LoadInput],
    storage: StorageLocations
) async -> FavoritesView.LoadResult {
    await Task.detached(priority: .userInitiated) {
        resolveFavorites(inputs, storage: storage)
    }.value
}

// MARK: - FavoritesList

/// The grouped favorites list, in its own `View` struct so `FavoritesView.body` stays small (a
/// single oversized view body tripped a SIL `ClosureLifetimeFixup` blow-up). One section per
/// file; an optional footnote when some favorites are still unresolved.
private struct FavoritesList: View {
    let groups: [FavoritesView.FavoriteGroup]
    let hasUnresolved: Bool
    let onTap: (PlacemarkIndex.Hit) -> Void

    var body: some View {
        List {
            ForEach(groups) { group in
                Section(group.entry.displayName) {
                    ForEach(group.hits) { hit in
                        Button {
                            onTap(hit)
                        } label: {
                            FavoriteRow(hit: hit)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if hasUnresolved {
                Section {
                    Text("Some favorites will appear after their files finish processing.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

// MARK: - FavoriteRow

/// One favorite row: a star, the placemark name (or a placeholder), and an optional coordinate
/// subtitle. Coordinates are plain "lat, lon" — a later localization task adds a real formatter.
private struct FavoriteRow: View {
    let hit: PlacemarkIndex.Hit

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "star.fill")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.name.isEmpty ? String(localized: "Unnamed place") : hit.name)
                    .lineLimit(1)
                if let subtitle = coordinateSubtitle(lat: hit.lat, lon: hit.lon) {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Formatting

/// The plain "lat, lon" subtitle for a coordinate, or `nil` when either component is missing.
/// A free function (not an inline closure in the row builder) to keep the view's SIL simple.
private func coordinateSubtitle(lat: Double?, lon: Double?) -> String? {
    guard let lat, let lon else { return nil }
    return "\(lat), \(lon)"
}

// MARK: - Off-main resolve

/// Reads each input entry's favorite keys from its sidecar and resolves them against its local
/// placemark index, producing per-file `FavoriteGroup`s (catalogue order, only entries with
/// resolvable favorites) plus a flag for whether any favorites remain unresolved.
///
/// A top-level `nonisolated` function (not a method on the `@MainActor` view) so it runs cleanly
/// off-main and, critically, isn't compiled inside the view's SIL function — see `load()`.
private func resolveFavorites(
    _ inputs: [FavoritesView.LoadInput],
    storage: StorageLocations
) -> FavoritesView.LoadResult {
    var groups: [FavoritesView.FavoriteGroup] = []
    var sawUnresolved = false
    for input in inputs {
        var keys: Set<String> = []
        if case let .ok(meta) = storage.readSidecar(forFolderNamed: input.folderName) {
            keys = meta.favoriteKeys
        }
        guard !keys.isEmpty else { continue }
        let hits = PlacemarkIndex.resolve(keys: keys, folderName: input.folderName, in: input.resourcesDir)
        if hits.isEmpty {
            // Favorites exist for this entry but its index resolved none — not yet materialized
            // (or all favorited placemarks dropped from the file).
            sawUnresolved = true
        } else {
            groups.append(FavoritesView.FavoriteGroup(entry: input.entry, hits: hits))
            // A partially-resolved entry (some favorites in the index, some not) still signals
            // there's more to come.
            if hits.count < keys.count { sawUnresolved = true }
        }
    }
    return FavoritesView.LoadResult(groups: groups, hasUnresolved: sawUnresolved)
}
