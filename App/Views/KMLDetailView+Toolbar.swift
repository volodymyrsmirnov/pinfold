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

    /// Sort order, the file's description, and — for an online list — Refresh Now, Copy URL and
    /// Stop Updating. While a refresh runs the label is a spinner and Refresh Now is disabled.
    private var moreMenu: some View {
        Menu {
            sortPicker
            if let info = documentInfo {
                Button {
                    infoSheet = info
                } label: {
                    Label("File Description", systemImage: "info.circle")
                }
            }
            onlineActions
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

    /// Document order vs. nearest first, as a "Sort By" submenu showing the current choice.
    /// Disabled until a location fix is known, so the person isn't offered a sort that can't be
    /// applied (without a fix the outline is in document order regardless).
    private var sortPicker: some View {
        Picker(selection: $nearestFirst) {
            Label("Document Order", systemImage: "list.bullet").tag(false)
            Label("Nearest First", systemImage: "location").tag(true)
        } label: {
            Label("Sort By", systemImage: "arrow.up.arrow.down")
        }
        .pickerStyle(.menu)
        .disabled(locationAuth.lastLocation == nil)
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
