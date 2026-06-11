import SwiftUI

// MARK: - HomeView tag filtering

/// The tag filter chips bar and its supporting partitions, factored out of `HomeView.swift` to
/// keep that file under the length limit. Shared by the Files list, which renders
/// `displayedActive` (the active entries narrowed to the selected chip).
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

// MARK: - EditTagsAlertModifier

/// The Edit Tags alert — a single TextField of comma-separated tags, prefilled by joining the
/// entry's current tags (see `beginEditTags` in HomeViewRows). Packaged as a `ViewModifier` so
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
