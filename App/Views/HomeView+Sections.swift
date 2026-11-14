import SwiftUI

// MARK: - HomeView sections

//
// The catalogue list's supporting sections, factored out of `HomeView.swift` to keep that file
// focused on the root layout, toolbar, and import flow. Everything here is one logical surface
// (the rows, their menus, the search results, and the import-failure banner), and a single file
// lets members used only between these pieces be `private` rather than file-spanning `internal`.
//
// Note on access control: `private` is file-scoped, so anything `HomeView.body` (in
// `HomeView.swift`) calls — `importFailureBanner`, `activeRowMenu`, `searchResults` — and any
// stored `@State` the extensions read (`placeHits`, `bulkSelection`, …) stays `internal`. Members
// both defined and used only within this file (e.g. `matchingFiles`, `groupedPlaceHits`, the
// row/hit helpers) are `private`.

// MARK: - Import-failure banner

extension HomeView {
    /// A dismissible banner listing recent import failures (parse or I/O) from any arrival
    /// path. Non-empty only when `ImportFailureLog` has recorded failures; "Clear" empties it.
    @ViewBuilder
    var importFailureBanner: some View {
        if !importFailureLog.failures.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label {
                        if importFailureLog.failures.count == 1 {
                            Text("1 file couldn't be imported")
                        } else {
                            Text("\(importFailureLog.failures.count) files couldn't be imported")
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("Clear") { importFailureLog.clear() }
                        .font(.subheadline)
                }
                ForEach(importFailureLog.failures.prefix(5)) { failure in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(failure.filename)
                            .font(.footnote.weight(.medium))
                        Text(failure.reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    // VoiceOver reads filename + reason as one element per failure.
                    .accessibilityElement(children: .combine)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }
}

// MARK: - Active-row actions (context menu and swipe actions)

extension HomeView {
    /// The context menu for an active (non-trashed) file row, in separated groups: Share (the
    /// original file on disk); Refresh Now, Copy URL and Stop Updating for online lists; Trash.
    /// Trashed rows use their own menu (Restore / Delete) and never get this one.
    func activeRowMenu(for entry: CatalogEntry) -> some View {
        FileActions(
            entry: entry,
            originalURL: FileShareLink.originalURL(for: entry, in: catalog.storage),
            isRefreshing: refresher.phase(for: entry) == .refreshing,
            handlers: fileActionHandlers(for: entry)
        )
    }

    /// What the catalogue's file actions do: Home's refresh-error alert, its Stop Updating
    /// confirmation, and a Trash that closes the file if it's the one open beside the list.
    func fileActionHandlers(for entry: CatalogEntry) -> FileActionHandlers {
        FileActionHandlers(
            refreshNow: { runRefreshNow(entry) },
            stopUpdating: { stopUpdatingTarget = entry },
            trash: { trash(entry) }
        )
    }

    /// An active file's row with all of its actions, the same wherever the file is listed (the
    /// Files list and the "Files" search results): swipe right for Share / Refresh / Trash, a
    /// full swipe left to Trash, and the long-press menu.
    func activeFileRow(_ entry: CatalogEntry) -> some View {
        FileRow(
            entry: entry,
            online: onlineStatus(for: entry),
            showsDisclosure: showsRowDisclosure,
            isHighlighted: !showsRowDisclosure && selection == entry.id
        )
        .tag(entry.id)
        // Full swipe left archives, as in Mail. Archiving is recoverable, so it isn't red.
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button {
                trash(entry)
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .tint(.purple)
            .disabled(entry.isReadOnly)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            fileRowLeadingActions(for: entry)
        }
        .contextMenu { activeRowMenu(for: entry) }
        .stopUpdatingConfirmation(target: $stopUpdatingTarget, entryID: entry.id, stop: runStopUpdating)
    }

    /// Moves `entry` to Trash from any of its actions (swipe, menu, menu bar). If it is the file
    /// open beside the list, it is closed first, as the file's own Trash does, so the detail
    /// doesn't blank in place and a later Restore doesn't silently reopen it.
    func trash(_ entry: CatalogEntry) {
        if selection == entry.id {
            selection = nil
        }
        Task { await catalog.moveToTrash(entry) }
    }

    /// The actions revealed by swiping a file row to the right, as place rows offer theirs:
    /// Share, Refresh (online lists only) and Trash. Share is left out while the original isn't
    /// on disk (an iCloud placeholder), as in the row menu.
    func fileRowLeadingActions(for entry: CatalogEntry) -> some View {
        FileSwipeActions(
            entry: entry,
            originalURL: FileShareLink.originalURL(for: entry, in: catalog.storage),
            isRefreshing: refresher.phase(for: entry) == .refreshing,
            handlers: fileActionHandlers(for: entry)
        )
    }
}

// MARK: - Search results

extension HomeView {
    /// Active entries whose display name matches the query — the "Files" results section.
    /// Same `localizedCaseInsensitiveContains` primitive as the placemark search.
    private var matchingFiles: [CatalogEntry] {
        sortedActive.filter { SearchText.contains($0.displayName, query: trimmedQuery) }
    }

    /// Place hits grouped by the entry that contains them, in catalogue order, so the results
    /// list can show one section per file. Resolves each hit's folder name to its entry.
    private var groupedPlaceHits: [(entry: CatalogEntry, hits: [PlacemarkIndex.Hit])] {
        let byFolder = Dictionary(grouping: placeHits, by: \.folderName)
        return active.compactMap { entry in
            guard let hits = byFolder[entry.storageFolderName], !hits.isEmpty else { return nil }
            return (entry, hits)
        }
    }

    /// Replaces the plain entry list while a query is active. Two sections:
    /// - "Files": active entries whose display name matches (selecting one opens it normally).
    /// - "Places": placemark hits from the per-entry indexes, grouped by file. Tapping a hit
    ///   selects its file AND sets `pendingPlacemarkKey` to the hit's stableKey, which
    ///   `KMLDetailView` resolves to push `PlacemarkDetailView` directly.
    ///
    /// Shows a `ContentUnavailableView` only when BOTH sections are empty (e.g. an index that
    /// hasn't been materialized yet contributes no Places hits — it self-heals on a later pass).
    @ViewBuilder
    var searchResults: some View {
        let files = matchingFiles
        let grouped = groupedPlaceHits
        if files.isEmpty, grouped.isEmpty {
            ContentUnavailableView.search(text: trimmedQuery)
        } else {
            List(selection: $selection) {
                if !files.isEmpty {
                    Section("Files") {
                        ForEach(files) { entry in
                            activeFileRow(entry)
                        }
                    }
                }
                ForEach(grouped, id: \.entry.id) { group in
                    Section(group.entry.displayName) {
                        ForEach(group.hits) { hit in
                            placeHitButton(hit)
                        }
                    }
                }
            }
            .catalogueListStyle()
        }
    }

    /// A "Places" hit with the same actions as the place inside its file (see "UI action
    /// consistency" in CLAUDE.md): tap opens it, swipe right for Share / Favorite / Mark Seen, and
    /// the long-press menu is the place's own (`PlacemarkActions`).
    private func placeHitButton(_ hit: PlacemarkIndex.Hit) -> some View {
        let place = PlaceRef(hit)
        let annotations = hitAnnotations[hit.folderName]
        return Button {
            openPlaceHit(hit)
        } label: {
            placeHitRow(hit, annotations: annotations)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            PlacemarkSwipeActions(place: place, annotations: annotations)
        }
        .contextMenu {
            PlacemarkActions(place: place, annotations: annotations)
        }
    }

    /// Favourites / Seen for each file the hits come from: the catalogue's shared store per
    /// file, the same instance an open file uses, so both always agree.
    func annotationsForHits(_ hits: [PlacemarkIndex.Hit]) -> [String: PlacemarkAnnotations] {
        var result: [String: PlacemarkAnnotations] = [:]
        for folder in Set(hits.map(\.folderName)) {
            guard let entry = active.first(where: { $0.storageFolderName == folder }) else { continue }
            result[folder] = catalog.annotations(for: entry)
        }
        return result
    }

    /// One "Places" hit row: the placemark name (or a coordinate-only placeholder) with its
    /// favourite star and Seen strikethrough as in the file's own rows, plus an excerpt line when
    /// the match was in the description, data or a note rather than the name.
    private func placeHitRow(_ hit: PlacemarkIndex.Hit, annotations: PlacemarkAnnotations?) -> some View {
        let isFavorite = annotations?.isFavorite(key: hit.key) ?? false
        let isVisited = annotations?.isVisited(key: hit.key) ?? false
        return HStack(spacing: 8) {
            Image(systemName: hit.matchedField == .note ? "note.text" : "mappin.circle")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if isFavorite {
                        Image(systemName: "star.fill")
                            .font(.footnote)
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("Favorite")
                    }
                    Text(hit.name.isEmpty ? "Unnamed place" : hit.name)
                        .strikethrough(isVisited)
                        .foregroundStyle(isVisited ? .secondary : .primary)
                        .lineLimit(1)
                        .accessibilityValue(isVisited ? Text("Seen") : Text(""))
                }
                if let snippet = hit.snippet {
                    Text(snippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if showsRowDisclosure {
                RowDisclosureIndicator()
            }
        }
        .contentShape(Rectangle())
    }

    /// Opens the file containing a Places hit, deep-linking to the placemark: seeds the one-shot
    /// `pendingPlacemarkKey` with the hit's stableKey, then selects the entry. `KMLDetailView`
    /// resolves the key after the file parses and pushes the placemark's detail page.
    ///
    /// Works for both selection states: a different file rebuilds `KMLDetailView` under a new
    /// identity (its load `.task` does the push); an already-open file keeps its identity but the
    /// `pendingPlacemarkKey` change re-evaluates the body, which `.onChange` consumes live.
    private func openPlaceHit(_ hit: PlacemarkIndex.Hit) {
        guard let entry = active.first(where: { $0.storageFolderName == hit.folderName }) else { return }
        // Seed the deep-link key BEFORE changing the selection so the detail view, rebuilt for
        // the new selection, reads it on its first load `.task`.
        pendingPlacemarkKey = hit.key
        selection = entry.id
    }
}
