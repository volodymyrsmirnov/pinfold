import SwiftUI

// MARK: - Multi-select (C8)

extension HomeView {
    /// Whether select mode makes sense right now: the plain Files list, not search results,
    /// not Trash, and at least one file.
    var canSelect: Bool {
        segment == .files && !isSearching && !active.isEmpty
    }

    /// The entries ticked in select mode, in list order.
    var bulkEntries: [CatalogEntry] {
        displayedActive.filter { bulkSelection.contains($0.id) }
    }

    /// The Files list in select mode. An explicit mode on every platform (the single-selection
    /// list drives the detail column, so it can't double as multi-select); edit mode is forced
    /// on so the selection checkmarks render on iPhone, iPad and Mac alike.
    var selectionList: some View {
        List(selection: $bulkSelection) {
            ForEach(displayedActive) { entry in
                FileRow(entry: entry)
                    .tag(entry.id)
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.editMode, .constant(.active))
    }

    func beginSelecting() {
        bulkSelection = []
        isSelecting = true
    }

    func endSelecting() {
        isSelecting = false
        bulkSelection = []
    }

    /// Trashes every ticked entry (one reload) and leaves select mode.
    func trashBulkSelection() {
        let entries = bulkEntries
        Task {
            await catalog.moveToTrash(entries)
            endSelecting()
        }
    }

    /// Opens the shared tags alert for the ticked entries.
    func beginBulkTagging() {
        bulkTagsText = ""
        bulkTagTargets = bulkEntries
    }

    /// Commits the bulk tags alert: the parts are added to each entry's existing tags.
    func saveBulkTags(_ entries: [CatalogEntry], _ parts: [String]) {
        Task {
            await catalog.addTags(parts, to: entries)
            endSelecting()
        }
    }

    /// The Select / Done toolbar button (Files segment only).
    @ToolbarContentBuilder
    var selectToolbarItem: some ToolbarContent {
        if canSelect || isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                Button(isSelecting ? "Done" : "Select") {
                    if isSelecting {
                        endSelecting()
                    } else {
                        beginSelecting()
                    }
                }
            }
        }
    }

    /// The bottom bar shown in select mode: Tag and Trash act on the ticked entries.
    @ToolbarContentBuilder
    var selectBottomBar: some ToolbarContent {
        if isSelecting {
            ToolbarItemGroup(placement: .bottomBar) {
                Button("Tag", systemImage: "tag") { beginBulkTagging() }
                    .disabled(bulkSelection.isEmpty)
                Spacer()
                Button("Trash", systemImage: "trash", role: .destructive) { trashBulkSelection() }
                    .disabled(bulkSelection.isEmpty)
            }
        }
    }
}
