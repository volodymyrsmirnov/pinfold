import SwiftUI

/// The Trash segment's list. Holds the confirmation state for deleting a single entry (swipe or
/// context menu); emptying the whole Trash is the toolbar's Empty button (`HomeView`).
struct TrashList: View {
    let trashed: [CatalogEntry]

    @Environment(Catalog.self) private var catalog

    @State private var pendingDelete: CatalogEntry?

    var body: some View {
        List {
            ForEach(trashed) { entry in
                row(for: entry)
            }
        }
        .listStyle(.insetGrouped)
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
