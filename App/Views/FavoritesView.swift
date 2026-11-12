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
/// search hit: it sets `pendingPlacemarkKey` to the placemark's stableKey and selects the
/// entry (see `HomeView.openPlaceHit`). The sheet dismisses first so the selection lands on
/// the underlying split view, which then pushes `PlacemarkDetailView`.
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

    /// One-shot deep-link target, owned by `RootView`. Set to the tapped favorite's stableKey so
    /// the opened file pushes straight to that placemark's detail page. See `RootView`.
    @Binding var pendingPlacemarkKey: String?

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
    /// List or map presentation (D7).
    @State private var mode: FavoritesMode = .list
    /// "Nearest first" ordering for the list; uses the device location when already available.
    @State private var nearestFirst = false
    /// The app's existing location facility (same one the file map and detail view use).
    @State private var locationAuth = LocationAuthorization()

    // MARK: - Body

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Favorites")
                .toolbar { toolbarContent }
        }
        // Re-load whenever the active catalogue identity set changes. The id is computed in a
        // helper (not an inline `.map` closure) to keep `body`'s SIL free of an extra closure.
        .task(id: activeEntryIDs) {
            await load()
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }
        }
        ToolbarItem(placement: .principal) {
            Picker("View", selection: $mode) {
                Text("List").tag(FavoritesMode.list)
                Text("Map").tag(FavoritesMode.map)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 180)
        }
        if mode == .list {
            ToolbarItem(placement: .cancellationAction) {
                Toggle("Nearest first", systemImage: "location.north.line", isOn: $nearestFirst)
                    .onChange(of: nearestFirst) { _, on in
                        // User-initiated; reuses the existing When-In-Use flow and usage string.
                        if on {
                            locationAuth.request()
                        }
                    }
            }
        }
    }

    /// The groups in display order: catalogue order, or nearest-first when requested and a fix exists.
    private func displayedGroups(_ groups: [FavoriteGroup]) -> [FavoriteGroup] {
        guard nearestFirst, let here = locationAuth.lastLocation else { return groups }
        return nearestOrdered(groups, latitude: here.coordinate.latitude, longitude: here.coordinate.longitude)
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
                if mode == .map {
                    FavoritesMapView(
                        pins: FavoritePins.pins(from: groups.flatMap(\.hits)),
                        fileNames: fileNames(of: groups),
                        onOpen: { open(folderName: $0.folderName, key: $0.key) }
                    )
                } else {
                    FavoritesList(
                        groups: displayedGroups(groups), hasUnresolved: hasUnresolvedFavorites,
                        onTap: { open(folderName: $0.folderName, key: $0.key) }
                    )
                }
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

    /// Deep-links into the favorite's file, mirroring `HomeView.openPlaceHit`: seed the one-shot
    /// `pendingPlacemarkKey` with the hit's stableKey, then select the entry. The sheet is
    /// dismissed FIRST so the selection change reaches the underlying split view — driving the
    /// detail column to the favorite's file and pushing the placemark's detail page.
    private func open(folderName: String, key: String) {
        guard let entry = catalog.active.first(where: { $0.storageFolderName == folderName }) else { return }
        dismiss()
        pendingPlacemarkKey = key
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

// MARK: - Mode and ordering

/// Whether the sheet shows the grouped list or the map.
enum FavoritesMode: Hashable {
    case list
    case map
}

/// Folder name to display name for the groups' files (map card subtitle).
private func fileNames(of groups: [FavoritesView.FavoriteGroup]) -> [String: String] {
    var names: [String: String] = [:]
    for group in groups {
        names[group.entry.storageFolderName] = group.entry.displayName
    }
    return names
}

/// Sorts each group's hits nearest-first and orders the groups by their nearest hit, groups
/// without any coordinate last (stable).
private func nearestOrdered(
    _ groups: [FavoritesView.FavoriteGroup], latitude: Double, longitude: Double
) -> [FavoritesView.FavoriteGroup] {
    let keyed = groups.enumerated().map { offset, group in
        let hits = FavoritePins.nearestFirst(group.hits, latitude: latitude, longitude: longitude)
        let nearest = hits.first.flatMap {
            FavoritePins.distance(of: $0, latitude: latitude, longitude: longitude)
        } ?? .infinity
        return (offset: offset, nearest: nearest, group: FavoritesView.FavoriteGroup(entry: group.entry, hits: hits))
    }
    return keyed.sorted {
        $0.nearest != $1.nearest ? $0.nearest < $1.nearest : $0.offset < $1.offset
    }.map(\.group)
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
            if hits.count < keys.count {
                sawUnresolved = true
            }
        }
    }
    return FavoritesView.LoadResult(groups: groups, hasUnresolved: sawUnresolved)
}
