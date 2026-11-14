import SwiftUI

/// What a file's actions do, supplied by the surface showing them: the catalogue (row menu and
/// swipe) or the open file's "⋯" menu. Each routes errors and closing its own way, while the
/// actions themselves — items, labels, icons, order, enablement — come from `FileActions` /
/// `FileSwipeActions`, so they can't drift apart (see "UI action consistency" in CLAUDE.md).
struct FileActionHandlers {
    /// Refresh Now (online lists).
    let refreshNow: () -> Void
    /// Stop Updating (online lists): asks for confirmation first.
    let stopUpdating: () -> Void
    /// Moves the file to the Archive (closing it if it is open); `nil` hides Archive.
    let trash: (() -> Void)?
}

/// The actions on one file, built once: the row's long-press menu and the open file's "⋯" menu.
///
/// Groups, each separated: Share (while the original is on disk); then any actions only the
/// caller's screen has (`screenActions` — the open file's Sort By and File Description, view
/// options of that screen); then Refresh Now / Copy URL / Stop Updating for an online list; then
/// Archive, last.
struct FileActions<ScreenActions: View>: View {
    let entry: CatalogEntry
    /// The original on disk, or `nil` (an iCloud placeholder) to leave Share out.
    let originalURL: URL?
    let isRefreshing: Bool
    let handlers: FileActionHandlers
    let screenActions: ScreenActions

    init(
        entry: CatalogEntry,
        originalURL: URL?,
        isRefreshing: Bool,
        handlers: FileActionHandlers,
        @ViewBuilder screenActions: () -> ScreenActions = { EmptyView() }
    ) {
        self.entry = entry
        self.originalURL = originalURL
        self.isRefreshing = isRefreshing
        self.handlers = handlers
        self.screenActions = screenActions()
    }

    var body: some View {
        if let originalURL {
            Section {
                FileShareLink(entry: entry, url: originalURL)
            }
        }
        Section {
            screenActions
        }
        if let subscription = entry.subscription {
            Section {
                Button(action: handlers.refreshNow) {
                    Label("Refresh Now", systemImage: "arrow.clockwise")
                }
                .disabled(entry.isReadOnly || isRefreshing)
                Button {
                    UIPasteboard.general.url = subscription.url
                } label: {
                    Label("Copy URL", systemImage: "link")
                }
                Button(action: handlers.stopUpdating) {
                    Label("Stop Updating", systemImage: "xmark.circle")
                }
                .disabled(entry.isReadOnly)
            }
        }
        if let trash = handlers.trash {
            Section {
                // Archive is recoverable (Restore from the Archive tab), so not destructive red.
                Button(action: trash) {
                    Label("Archive", systemImage: "archivebox")
                }
                .disabled(entry.isReadOnly)
            }
        }
    }
}

/// A file row's swipe-right actions, a subset of `FileActions` with the short labels swipe
/// buttons need: Share, Refresh (online lists), Archive.
struct FileSwipeActions: View {
    let entry: CatalogEntry
    let originalURL: URL?
    let isRefreshing: Bool
    let handlers: FileActionHandlers

    var body: some View {
        if let originalURL {
            FileShareLink(entry: entry, url: originalURL)
                .tint(.blue)
        }
        if entry.subscription != nil {
            Button(action: handlers.refreshNow) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .tint(.indigo)
            .disabled(entry.isReadOnly || isRefreshing)
        }
        if let trash = handlers.trash {
            Button(action: trash) {
                Label("Archive", systemImage: "archivebox")
            }
            .tint(.purple)
            .disabled(entry.isReadOnly)
        }
    }
}

/// Share for a file: the original .kml/.kmz/.gpx/.geojson itself.
struct FileShareLink: View {
    let entry: CatalogEntry
    let url: URL

    var body: some View {
        ShareLink(item: url, preview: SharePreview(entry.displayName)) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
    }

    /// The entry's original file, but only if it currently exists on disk, so Share never offers
    /// a dead iCloud-placeholder URL. A cheap `fileExists` stat, fine to call while building a
    /// menu.
    static func originalURL(for entry: CatalogEntry, in storage: StorageLocations) -> URL? {
        guard let url = storage.originalFileURL(inFolderNamed: entry.storageFolderName),
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }
}
