import SwiftUI

/// The Trash segment's list. Swipe a row to the right (or long-press it) to Restore it or Delete
/// it for good. Deleting asks no confirmation: it's Trash, so a file there is already on its way
/// out. Bulk deletion is the toolbar's Select mode (`HomeView`).
struct TrashList: View {
    let trashed: [CatalogEntry]

    @Environment(Catalog.self) private var catalog

    var body: some View {
        List {
            ForEach(trashed) { entry in
                row(for: entry)
            }
        }
        .catalogueListStyle()
    }

    private func row(for entry: CatalogEntry) -> some View {
        FileRow(entry: entry)
            // Leading, like the Files rows' Share / Refresh / Trash swipe.
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                restoreButton(entry).tint(.blue)
                deleteButton(entry)
            }
            .contextMenu {
                restoreButton(entry)
                Section {
                    deleteButton(entry)
                }
            }
    }

    private func deleteButton(_ entry: CatalogEntry) -> some View {
        Button(role: .destructive) {
            Task { await catalog.deleteForever(entry) }
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
