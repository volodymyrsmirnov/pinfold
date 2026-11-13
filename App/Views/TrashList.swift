import SwiftUI

/// The Trash segment's list. Holds the confirmation state for permanent deletion: a single
/// entry (swipe or context menu) or the whole Trash ("Empty Trash").
struct TrashList: View {
    let trashed: [CatalogEntry]
    /// Select mode owns the bottom bar, so the Empty Trash item steps aside while it is on.
    var isSelecting = false

    @Environment(Catalog.self) private var catalog

    @State private var pendingDelete: CatalogEntry?
    @State private var isConfirmingEmpty = false

    var body: some View {
        List {
            Section {
                ForEach(trashed) { entry in
                    row(for: entry)
                }
            } footer: {
                Text("Items in Trash can be restored or deleted permanently.")
            }
        }
        .listStyle(.insetGrouped)
        .toolbar { emptyTrashToolbar }
        .confirmationDialog(
            "Delete permanently?",
            isPresented: isConfirmingSingle,
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { entry in
            Button("Delete Permanently", role: .destructive) {
                Task { await catalog.deleteForever(entry) }
            }
        } message: { entry in
            Text("\u{201C}\(entry.displayName)\u{201D} will be deleted and can't be recovered.")
        }
        .confirmationDialog(
            "Empty Trash?",
            isPresented: $isConfirmingEmpty,
            titleVisibility: .visible
        ) {
            Button("Delete \(trashed.count) Permanently", role: .destructive) {
                Task { await catalog.emptyTrash() }
            }
        } message: {
            Text("Everything in Trash will be deleted and can't be recovered.")
        }
    }

    /// Files / Photos-style "Recently Deleted" control: a red plain-text item at the trailing
    /// end of the bottom bar. The flexible spacer keeps it right-aligned and lets the import
    /// progress label (also a bottom-bar item) sit at the leading end when both show.
    @ToolbarContentBuilder
    private var emptyTrashToolbar: some ToolbarContent {
        if !trashed.isEmpty, !isSelecting {
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button("Empty Trash", role: .destructive) { isConfirmingEmpty = true }
                    .tint(.red)
            }
        }
    }

    private var isConfirmingSingle: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: {
                if !$0 {
                    pendingDelete = nil
                }
            }
        )
    }

    private func row(for entry: CatalogEntry) -> some View {
        FileRow(entry: entry)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                deleteButton(entry)
                restoreButton(entry).tint(.blue)
            }
            .contextMenu {
                restoreButton(entry)
                deleteButton(entry)
            }
    }

    private func deleteButton(_ entry: CatalogEntry) -> some View {
        Button(role: .destructive) {
            pendingDelete = entry
        } label: {
            Label("Delete", systemImage: "trash.fill")
        }
    }

    private func restoreButton(_ entry: CatalogEntry) -> some View {
        Button {
            Task { await catalog.restore(entry) }
        } label: {
            Label("Restore", systemImage: "arrow.uturn.backward")
        }
    }
}
