import SwiftUI

// MARK: - HomeView search results

/// The catalogue-wide search results UI for `HomeView`, factored into its own file to keep
/// `HomeView.swift` focused on the catalogue list + import flow. Rendered by `fileList` when
/// a query is active on the Files segment.
extension HomeView {
    /// Replaces the plain entry list while a query is active. Two sections:
    /// - "Files": active entries whose display name matches (selecting one opens it normally).
    /// - "Places": placemark hits from the per-entry indexes, grouped by file. Tapping a hit
    ///   selects its file AND seeds the detail view's outline filter with the placemark name
    ///   (via `pendingDetailSearch`), deep-linking to the placemark.
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

    /// Opens the file containing a Places hit, deep-linking to the placemark: selects the
    /// entry and hands the placemark name to the detail view as a one-shot outline filter.
    ///
    /// Works for both selection states:
    /// - **Different file**: the selection change rebuilds `KMLDetailView` under a new
    ///   identity; its `.task(id: entry.id)` reads `initialSearch` on first load.
    /// - **Already-open file**: `selection = entry.id` is a same-value write (no identity
    ///   change), but the `pendingDetailSearch` nil→name change alone re-evaluates the detail
    ///   body with the new `initialSearch` param, which the detail's
    ///   `.onChange(of: initialSearch)` consumes live.
    private func openPlaceHit(_ hit: PlacemarkIndex.Hit) {
        guard let entry = active.first(where: { $0.storageFolderName == hit.folderName }) else { return }
        // Seed the deep-link filter BEFORE changing the selection so the detail view, rebuilt
        // for the new selection, reads the pending search on its first load `.task`.
        pendingDetailSearch = hit.name.isEmpty ? nil : hit.name
        selection = entry.id
    }
}
