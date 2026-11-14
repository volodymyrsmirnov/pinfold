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
        sortedActive.filter { bulkSelection.contains($0.id) }
    }

    /// Whether every file in the list is ticked (Select All then reads Deselect All).
    var isEverythingSelected: Bool {
        !active.isEmpty && active.allSatisfy { bulkSelection.contains($0.id) }
    }

    /// The Files list in select mode. An explicit mode on every platform (the single-selection
    /// list drives the detail column, so it can't double as multi-select); edit mode is forced
    /// on so the selection checkmarks render on iPhone, iPad and Mac alike.
    var selectionList: some View {
        List(selection: $bulkSelection) {
            ForEach(sortedActive) { entry in
                FileRow(entry: entry, online: onlineStatus(for: entry))
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

    /// Select All / Deselect All, in place of the "+" menu while selecting (as in Mail).
    var selectAllButton: some View {
        Button(isEverythingSelected ? "Deselect All" : "Select All") {
            if isEverythingSelected {
                bulkSelection = []
            } else {
                bulkSelection = Set(active.map(\.id))
            }
        }
    }

    /// The Select / Done text button (Files segment only), in its own pill before the gear.
    @ToolbarContentBuilder
    var selectToolbarItem: some ToolbarContent {
        if canSelect || isSelecting {
            ToolbarItem(placement: .topBarTrailing) {
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

    /// The bottom bar shown in select mode: how many files are ticked, and Trash for them.
    @ToolbarContentBuilder
    var selectBottomBar: some ToolbarContent {
        if isSelecting {
            // Plain text like Mail's "N Selected", not a glass button.
            ToolbarItem(placement: .status) {
                Text(selectionCountText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button("Trash", systemImage: "trash", role: .destructive) { trashBulkSelection() }
                    .disabled(bulkSelection.isEmpty)
            }
        }
    }

    /// "Select Files" before anything is ticked, then "1 File Selected" / "N Files Selected".
    private var selectionCountText: String {
        switch bulkSelection.count {
        case 0: String(localized: "Select Files")
        case 1: String(localized: "1 File Selected")
        default: String(localized: "\(bulkSelection.count) Files Selected")
        }
    }
}
