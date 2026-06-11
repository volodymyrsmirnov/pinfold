import SwiftUI

// MARK: - HomeView active-row actions

/// The context menu and rename plumbing for active (non-trashed) file rows, factored out of
/// `HomeView.swift` to keep that file focused on layout + the import flow. Shared by the plain
/// Files list and the "Files" search-results section.
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
}
