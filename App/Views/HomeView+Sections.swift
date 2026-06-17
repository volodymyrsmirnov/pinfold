import SwiftUI

// MARK: - HomeView sections

//
// The catalogue list's supporting sections, factored out of `HomeView.swift` to keep that file
// focused on the root layout, toolbar, and import flow. Merged from the former
// `HomeViewBanner` / `HomeViewTags` / `HomeViewRows` / `HomeSearchResults` files: everything here
// is one logical surface (the rows, their menus, the tag-filter chips, the search results, and
// the import-failure banner), and a single file lets members used only between these pieces be
// `private` rather than file-spanning `internal`.
//
// Note on access control: `private` is file-scoped, so anything `HomeView.body` (in
// `HomeView.swift`) calls — `importFailureBanner`, `tagChipsBar`, `displayedActive`, `allTags`,
// `resetStaleTagFilter`, `saveTags`, `activeRowMenu`, `searchResults` — and any stored `@State`
// the extensions read (`placeHits`, `renameText`, …) stays `internal`. Members both defined and
// used only within this file (e.g. `matchingFiles`, `groupedPlaceHits`, the row/hit helpers) are
// `private`.

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

// MARK: - Tag filtering

extension HomeView {
    /// `sortedActive` narrowed to the selected filter chip's tag, if any. "All" (`selectedTag ==
    /// nil`) shows everything. Matching is case-insensitive against each entry's stored tags.
    var displayedActive: [CatalogEntry] {
        guard let selectedTag else { return sortedActive }
        return sortedActive.filter { entry in
            entry.tags.contains { $0.localizedCaseInsensitiveCompare(selectedTag) == .orderedSame }
        }
    }

    /// Every distinct tag across the active entries, sorted case-insensitively — the source for
    /// the filter chips. Empty when no active entry has a tag (the chips bar then hides).
    var allTags: [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for entry in active {
            for tag in entry.tags where seen.insert(tag.lowercased()).inserted {
                result.append(tag)
            }
        }
        return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Clears `selectedTag` when it is no longer one of the live tags, so the Files list never
    /// silently filters to empty. Called from an `.onChange(of: allTags)` on HomeView's
    /// always-mounted body — NOT from inside `tagChipsBar` — because the bar is conditionally
    /// mounted on `!allTags.isEmpty`: when the LAST tagged entry is untagged/trashed while its
    /// tag is the active filter, the bar (and any `.onChange` attached to it) unmounts in the
    /// same update WITHOUT firing, leaving `selectedTag` stale, `displayedActive` empty, and no
    /// chips visible to recover. Hoisted to the body, the reset covers BOTH that all-tags-gone
    /// case (`tags` empty → `contains` fails → reset) and the partial-vanish case (the selected
    /// tag gone while other tags remain).
    func resetStaleTagFilter(_ tags: [String]) {
        if let selectedTag, !tags.contains(selectedTag) { self.selectedTag = nil }
    }

    /// Commits the Edit Tags alert: hands the raw comma-split parts to `catalog.setTags`, which
    /// trims/dedupes/sorts them (see `Catalog.normalizeTags`). A named method (not an inline
    /// closure in `body`) so the `.modifier(...)` line stays cheap to type-check.
    func saveTags(_ entry: CatalogEntry, _ parts: [String]) {
        Task { await catalog.setTags(parts, for: entry) }
    }

    /// A horizontally-scrolling row of tag filter chips, shown only on the Files segment, only
    /// when not searching, and only when at least one active entry has a tag. An "All" chip
    /// clears the filter; each tag chip toggles `selectedTag`. Hidden during search to keep the
    /// filter state simple (chips + search would otherwise need an AND/OR policy).
    @ViewBuilder
    var tagChipsBar: some View {
        if segment == .files, !isSearching, !allTags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    TagChip(label: String(localized: "All"), isSelected: selectedTag == nil) {
                        selectedTag = nil
                    }
                    ForEach(allTags, id: \.self) { tag in
                        TagChip(label: tag, isSelected: selectedTag == tag) {
                            selectedTag = (selectedTag == tag) ? nil : tag
                        }
                    }
                }
                .padding(.horizontal)
            }
            .padding(.bottom, 8)
            // NOTE: the stale-selectedTag reset deliberately does NOT live here. This bar is
            // conditionally mounted (`!allTags.isEmpty`): when the LAST tagged entry loses its
            // tag, the bar unmounts in the same update and an `.onChange` attached here would
            // never fire — `selectedTag` would go stale and the list would filter to empty
            // with no chips visible to recover. The reset lives on HomeView's always-mounted
            // body instead (`.onChange(of: allTags)` in HomeView.swift), which calls
            // `resetStaleTagFilter` above.
        }
    }
}

// MARK: - Active-row actions (context menu + rename/tags plumbing)

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
        Button {
            beginEditTags(entry)
        } label: {
            Label("Edit Tags\u{2026}", systemImage: "tag")
        }
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
        Button(role: .destructive) {
            Task { await catalog.moveToTrash(entry) }
        } label: {
            Label("Trash", systemImage: "trash")
        }
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
    private func beginRename(_ entry: CatalogEntry) {
        renameText = entry.displayName
        renameTarget = entry
    }

    /// Opens the Edit Tags alert for `entry`, prefilling the field with its current tags joined
    /// by ", " (the same separator the Save action parses back on).
    private func beginEditTags(_ entry: CatalogEntry) {
        tagsText = entry.tags.joined(separator: ", ")
        tagsTarget = entry
    }
}

// MARK: - Search results

extension HomeView {
    /// Active entries whose display name matches the query — the "Files" results section.
    /// Same `localizedCaseInsensitiveContains` primitive as the placemark search.
    private var matchingFiles: [CatalogEntry] {
        sortedActive.filter { $0.displayName.localizedCaseInsensitiveContains(trimmedQuery) }
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
                            FileRow(entry: entry)
                                .tag(entry.id)
                                .contextMenu { activeRowMenu(for: entry) }
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

    /// One "Places" hit row: the placemark name (or a coordinate-only placeholder).
    private func placeHitRow(_ hit: PlacemarkIndex.Hit) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "mappin.circle")
                .foregroundStyle(.secondary)
            Text(hit.name.isEmpty ? "Unnamed place" : hit.name)
                .lineLimit(1)
            Spacer(minLength: 0)
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

// MARK: - EditTagsAlertModifier

/// The Edit Tags alert — a single TextField of comma-separated tags, prefilled by joining the
/// entry's current tags (see `beginEditTags` above). Packaged as a `ViewModifier` so
/// `HomeView.body`'s already-long modifier chain carries one `.modifier(...)` line instead of
/// the full alert closure tree, which pushed the expression past the type-checker's budget.
struct EditTagsAlertModifier: ViewModifier {
    /// The entry being edited; non-nil presents the alert, dismissal nils it.
    @Binding var target: CatalogEntry?
    /// The comma-separated tags text bound to the alert's TextField.
    @Binding var text: String
    /// Commit callback: the entry plus the raw comma-split parts (normalization is the
    /// callee's job — see `HomeView.saveTags`).
    let save: (CatalogEntry, [String]) -> Void

    func body(content: Content) -> some View {
        content.alert(
            "Edit Tags",
            isPresented: Binding(
                get: { target != nil },
                set: { if !$0 { target = nil } }
            ),
            presenting: target
        ) { entry in
            TextField("Tags, comma-separated", text: $text)
            Button("Save") {
                save(entry, text.split(separator: ",").map(String.init))
                target = nil
            }
            Button("Cancel", role: .cancel) { target = nil }
        } message: { _ in
            Text("Separate tags with commas.")
        }
    }
}
