import SwiftUI

extension HomeView {
    /// The catalogue toolbar, laid out like Mail's mailbox list:
    /// - leading: the "+" import menu (Select All / Deselect All while selecting);
    /// - trailing: Select as a text button in its own pill (Files and Trash alike), then the
    ///   Settings gear in another;
    /// - bottom bar: the import progress status, or the select-mode actions.
    ///
    /// Kept out of `body` to keep its type-checking small.
    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if isSelecting {
                selectAllButton
            } else {
                importMenu
            }
        }
        selectToolbarItem
        if !isSelecting {
            // Keeps the Select text button in a pill of its own, apart from the gear.
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isSettingsPresented = true
                } label: {
                    Label("Settings", systemImage: "gear")
                }
            }
        }
        selectBottomBar
        // Import progress: a spinner plus the current filename, shown only while the
        // coordinator is draining its queue (e.g. a large KMZ that takes a moment).
        // Placed in the bottom bar (`.bottomBar`) rather than `.principal`: a principal
        // item REPLACES the navigation title on compact width, which made the "Pinfold"
        // title vanish mid-import. The status bar floats below the list and leaves the
        // title intact on every size class. Hidden while select mode owns the bottom bar,
        // and the import menu is disabled during an import anyway.
        if isSubscribing, !isSelecting {
            ToolbarItem(placement: .bottomBar) {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Downloading\u{2026}").font(.subheadline)
                }
            }
        } else if importCoordinator.isImporting, !isSelecting {
            ToolbarItem(placement: .bottomBar) {
                ImportProgressLabel(coordinator: importCoordinator)
            }
        }
    }

    /// The "+" menu: import a file from the device, or follow a list at a web address.
    private var importMenu: some View {
        Menu {
            Button("Local File", systemImage: "doc") {
                isFileImporterPresented = true
            }
            Button("Remote URL", systemImage: "globe") {
                beginSubscribe()
            }
            .disabled(isSubscribing)
        } label: {
            Label("Import", systemImage: "plus")
        }
        // While an import is in flight the menu is disabled and the bottom-bar progress shows
        // the work. Also disabled while a duplicate alert stalls the queue: the coordinator is
        // waiting on the user's decision, so offering more imports would contradict the
        // stalled state (queued URLs are kept either way).
        .disabled(importCoordinator.isImporting || importCoordinator.pendingDuplicate != nil || isSubscribing)
    }

    /// This window's menu-command actions, published as a focused-scene value (E7). Acts on the
    /// sidebar's selected file; the pure model decides what is enabled.
    var windowCommands: WindowCommands {
        let selected = isSelecting ? nil : selection.flatMap { id in active.first { $0.id == id } }
        return WindowCommands(
            // In select mode the ticked rows, not the open file, are what the user has in hand,
            // so the single-file commands stand down rather than act on a file that isn't ticked.
            selectedEntry: selected,
            canImport: !importCoordinator.isImporting && importCoordinator.pendingDuplicate == nil
                && !isSubscribing,
            importFiles: { isFileImporterPresented = true },
            subscribeToURL: { beginSubscribe() },
            focusSearch: { isSearchFocused = true },
            trash: { trash($0) },
            refreshNow: { runRefreshNow($0) },
            copyURL: { entry in UIPasteboard.general.url = entry.subscription?.url },
            stopUpdating: { stopUpdatingTarget = $0 },
            isRefreshingSelection: selected.map { refresher.phase(for: $0) == .refreshing } ?? false
        )
    }
}
