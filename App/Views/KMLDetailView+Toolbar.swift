import SwiftUI

extension KMLDetailView {
    /// The file's toolbar, grouped like Mail's: one "More" menu for the secondary actions, and
    /// the Map in a pill of its own as the screen's primary action.
    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) { moreMenu }
        ToolbarSpacer(.fixed, placement: .topBarTrailing)
        ToolbarItem(placement: .topBarTrailing) {
            NavigationLink(value: EntryRoute.map(focusKey: nil)) {
                Label("Map", systemImage: "map")
            }
            .disabled(outline?.mappablePlacemarks.isEmpty ?? true)
        }
    }

    /// In separated groups: Share; sort order and the file's description; for an online list
    /// Refresh Now, Copy URL and Stop Updating; and Trash. While a refresh runs the label is a
    /// spinner and Refresh Now is disabled.
    private var moreMenu: some View {
        Menu {
            if let url = existingOriginalURL {
                Section {
                    ShareLink(item: url, preview: SharePreview(liveEntry.displayName)) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }
            Section {
                sortPicker
                if let info = documentInfo {
                    Button {
                        infoSheet = info
                    } label: {
                        Label("File Description", systemImage: "info.circle")
                    }
                }
            }
            onlineActions
            if catalog != nil {
                Section {
                    Button(role: .destructive, action: trashAndClose) {
                        Label("Trash", systemImage: "trash")
                    }
                    .disabled(liveEntry.isReadOnly)
                }
            }
        } label: {
            // Fixed frame so the toolbar pill keeps its size when the glyph becomes a spinner.
            Group {
                if isRefreshing {
                    ProgressView()
                } else {
                    Image(systemName: "ellipsis")
                }
            }
            .frame(width: 24, height: 24)
        }
        .accessibilityLabel("More")
        .stopUpdatingConfirmation(target: $stopUpdatingTarget) { target in
            guard let refresher else { return }
            Task { await showRefreshError(refresher.stopUpdatingMessage(target)) }
        }
    }

    /// Document order vs. nearest first, as a "Sort By" submenu with a checkmark on the current
    /// choice. Only "Nearest First" waits for a location fix (it can't be applied without one);
    /// "Document Order" stays available, so a restored nearest-first list can always go back.
    private var sortPicker: some View {
        Menu {
            Toggle(isOn: sortBinding(nearest: false)) {
                Label("Document Order", systemImage: "list.bullet")
            }
            Toggle(isOn: sortBinding(nearest: true)) {
                Label("Nearest First", systemImage: "location")
            }
            .disabled(locationAuth.lastLocation == nil && !nearestFirst)
        } label: {
            Label("Sort By", systemImage: nearestFirst ? "location" : "arrow.up.arrow.down")
        }
    }

    /// On when the sort is `nearest`; turning it on selects that sort.
    private func sortBinding(nearest: Bool) -> Binding<Bool> {
        Binding(
            get: { nearestFirst == nearest },
            set: { isOn in
                if isOn {
                    nearestFirst = nearest
                }
            }
        )
    }

    /// The file's original on disk, for Share; `nil` while it isn't there (an iCloud
    /// placeholder not yet downloaded), so Share never offers a dead URL.
    private var existingOriginalURL: URL? {
        guard let url = storage.originalFileURL(inFolderNamed: liveEntry.storageFolderName),
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    /// Moves the file to Trash and closes it, back to the file list. Closes first so the screen
    /// slides away rather than blanking when the catalogue reload drops the entry; if the move
    /// fails (a read-only sidecar), the catalogue reports it and the file stays in the list.
    private func trashAndClose() {
        guard let catalog else { return }
        let target = liveEntry
        router?.closeEntry()
        Task { await catalog.moveToTrash(target) }
    }

    private var isRefreshing: Bool {
        guard let refresher, liveEntry.isOnline else { return false }
        return refresher.phase(for: liveEntry) == .refreshing
    }

    /// The online-list actions, in their own menu section; nothing for a normal list.
    @ViewBuilder
    private var onlineActions: some View {
        if let refresher, let subscription = liveEntry.subscription {
            let live = liveEntry
            Section {
                Button {
                    Task { await showRefreshError(refresher.refreshNowMessage(live)) }
                } label: {
                    Label("Refresh Now", systemImage: "arrow.clockwise")
                }
                .disabled(live.isReadOnly || isRefreshing)
                Button {
                    UIPasteboard.general.url = subscription.url
                } label: {
                    Label("Copy URL", systemImage: "link")
                }
                Button {
                    stopUpdatingTarget = live
                } label: {
                    Label("Stop Updating", systemImage: "xmark.circle")
                }
                .disabled(live.isReadOnly)
            }
        }
    }
}
