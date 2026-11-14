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
// stored `@State` the extensions read (`placeHits`, `renameText`, …) stays `internal`. Members
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

// MARK: - Active-row actions (context menu + rename plumbing)

extension HomeView {
    /// The context menu for an active (non-trashed) file row. Offers Rename, Share (the
    /// original file on disk), and Trash. Trashed rows use a different menu (restore/delete)
    /// and never get this one.
    @ViewBuilder
    func activeRowMenu(for entry: CatalogEntry) -> some View {
        Button {
            beginRename(entry)
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        .disabled(entry.isReadOnly)
        // Share the original .kml/.kmz back out. `ShareLink` with a file URL shares the file
        // itself. Shown only when the original actually exists on disk: in iCloud mode an entry
        // can be a not-yet-downloaded placeholder, and ShareLink would otherwise render a
        // tappable item that shares a dead URL. `existingOriginalURL` does a cheap `fileExists`
        // stat — fine to evaluate while building the (lazily-built) menu.
        if let url = existingOriginalURL(for: entry) {
            ShareLink(item: url, preview: SharePreview(entry.displayName)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
        if let subscription = entry.subscription {
            onlineRowMenu(for: entry, url: subscription.url)
        }
        Button(role: .destructive) {
            Task { await catalog.moveToTrash(entry) }
        } label: {
            Label("Trash", systemImage: "trash")
        }
        .disabled(entry.isReadOnly)
    }

    /// The actions revealed by swiping a file row to the right, as place rows offer theirs:
    /// Share, Refresh (online lists only) and Trash. Share is left out while the original isn't
    /// on disk (an iCloud placeholder), as in the row menu.
    @ViewBuilder
    func fileRowLeadingActions(for entry: CatalogEntry) -> some View {
        if let url = existingOriginalURL(for: entry) {
            ShareLink(item: url, preview: SharePreview(entry.displayName)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .tint(.blue)
        }
        if entry.subscription != nil {
            Button {
                runRefreshNow(entry)
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .tint(.indigo)
            .disabled(entry.isReadOnly || refresher.phase(for: entry) == .refreshing)
        }
        Button(role: .destructive) {
            Task { await catalog.moveToTrash(entry) }
        } label: {
            Label("Trash", systemImage: "trash")
        }
        .disabled(entry.isReadOnly)
    }

    /// Refresh Now / Copy URL / Stop Updating, for online lists only.
    @ViewBuilder
    private func onlineRowMenu(for entry: CatalogEntry, url: URL) -> some View {
        Button {
            runRefreshNow(entry)
        } label: {
            Label("Refresh Now", systemImage: "arrow.clockwise")
        }
        .disabled(entry.isReadOnly || refresher.phase(for: entry) == .refreshing)
        Button {
            UIPasteboard.general.url = url
        } label: {
            Label("Copy URL", systemImage: "link")
        }
        Button {
            stopUpdatingTarget = entry
        } label: {
            Label("Stop Updating", systemImage: "xmark.circle")
        }
        .disabled(entry.isReadOnly)
    }

    /// The entry's original KML/KMZ file URL, but only if it currently exists on disk (so the
    /// Share action never offers a dead iCloud-placeholder URL). `nil` when absent.
    private func existingOriginalURL(for entry: CatalogEntry) -> URL? {
        guard let url = catalog.storage.originalFileURL(inFolderNamed: entry.storageFolderName),
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    /// Opens the rename alert for `entry`, prefilling the field with its current name.
    func beginRename(_ entry: CatalogEntry) {
        renameText = entry.displayName
        renameTarget = entry
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
                            FileRow(entry: entry, online: onlineStatus(for: entry), showsDisclosure: showsRowDisclosure)
                                .tag(entry.id)
                                .contextMenu { activeRowMenu(for: entry) }
                                .stopUpdatingConfirmation(
                                    target: $stopUpdatingTarget, entryID: entry.id, stop: runStopUpdating
                                )
                        }
                    }
                }
                ForEach(grouped, id: \.entry.id) { group in
                    Section(group.entry.displayName) {
                        ForEach(group.hits) { hit in
                            Button {
                                openPlaceHit(hit)
                            } label: {
                                placeHitRow(hit)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    /// One "Places" hit row: the placemark name (or a coordinate-only placeholder), plus an
    /// excerpt line when the match was in the description, data or a note rather than the name.
    private func placeHitRow(_ hit: PlacemarkIndex.Hit) -> some View {
        HStack(spacing: 8) {
            Image(systemName: hit.matchedField == .note ? "note.text" : "mappin.circle")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.name.isEmpty ? "Unnamed place" : hit.name)
                    .lineLimit(1)
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
