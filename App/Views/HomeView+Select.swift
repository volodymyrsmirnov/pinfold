import SwiftUI

// MARK: - Multi-select (C8)

extension HomeView {
    /// The rows select mode works on: the Files list (newest first) or the Trash list, in the
    /// order each one shows them.
    var selectableEntries: [CatalogEntry] {
        segment == .files ? sortedActive : visibleTrashed
    }

    /// Whether select mode makes sense right now: a plain list (not search results) with at
    /// least one file, on either segment.
    var canSelect: Bool {
        trimmedQuery.isEmpty && !selectableEntries.isEmpty
    }

    /// The entries ticked in select mode, in list order.
    var bulkEntries: [CatalogEntry] {
        selectableEntries.filter { bulkSelection.contains($0.id) }
    }

    /// Whether every file in the list is ticked (Select All then reads Deselect All).
    var isEverythingSelected: Bool {
        let entries = selectableEntries
        return !entries.isEmpty && entries.allSatisfy { bulkSelection.contains($0.id) }
    }

    /// The Files or Trash list in select mode. An explicit mode on every platform (the Files
    /// list's single selection drives the detail column, so it can't double as multi-select);
    /// edit mode is forced on so the selection checkmarks render on iPhone, iPad and Mac alike.
    var selectionList: some View {
        List(selection: $bulkSelection) {
            ForEach(selectableEntries) { entry in
                FileRow(entry: entry, online: segment == .files ? onlineStatus(for: entry) : nil)
                    .tag(entry.id)
            }
        }
        .catalogueListStyle()
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
        // The open file is closed if it's among them, as when trashing it on its own.
        if let selection, bulkSelection.contains(selection) {
            self.selection = nil
        }
        Task {
            await catalog.moveToTrash(entries)
            endSelecting()
        }
    }

    /// Deletes every ticked Trash entry for good (one reload) and leaves select mode. No
    /// confirmation: it's Trash, so the files are already on their way out.
    func deleteBulkSelection() {
        let entries = bulkEntries
        Task {
            await catalog.deleteForever(entries)
            endSelecting()
        }
    }

    /// Select All / Deselect All, in place of the "+" menu while selecting (as in Mail).
    var selectAllButton: some View {
        Button(isEverythingSelected ? "Deselect All" : "Select All") {
            if isEverythingSelected {
                bulkSelection = []
            } else {
                bulkSelection = Set(selectableEntries.map(\.id))
            }
        }
    }

    /// The Select / Done text button, in its own pill before the gear.
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

    /// The bottom bar shown in select mode: how many files are ticked, and Trash for them (Files)
    /// or Delete, which removes them for good (Trash).
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
                if segment == .files {
                    Button("Trash", systemImage: "trash", role: .destructive) { trashBulkSelection() }
                        .disabled(bulkEntries.isEmpty)
                } else {
                    // Deleting for good wears the same filled red glyph as a Trash row's Delete,
                    // so it can't be mistaken for the recoverable Trash button in Files.
                    Button("Delete", systemImage: "trash.fill", role: .destructive) { deleteBulkSelection() }
                        .tint(.red)
                        .disabled(bulkEntries.isEmpty)
                }
            }
        }
    }

    /// "Select Files" before anything is ticked, then "1 File Selected" / "N Files Selected".
    /// Counts the ticked files still in the list, so a file removed meanwhile (iCloud, another
    /// window) drops out of the count.
    private var selectionCountText: String {
        let count = bulkEntries.count
        return switch count {
        case 0: String(localized: "Select Files")
        case 1: String(localized: "1 File Selected")
        default: String(localized: "\(count) Files Selected")
        }
    }
}
