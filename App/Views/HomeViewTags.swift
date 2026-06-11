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
            // If the selected tag disappears (e.g. its last entry is renamed/untagged/trashed),
            // fall back to "All" so the list never silently shows nothing.
            .onChange(of: allTags) { _, tags in
                if let selectedTag, !tags.contains(selectedTag) { self.selectedTag = nil }
            }
        }
    }
}
