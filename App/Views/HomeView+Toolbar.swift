import SwiftUI

extension HomeView {
    /// The catalogue toolbar, laid out like Mail's mailbox list:
    /// - leading: the "+" import menu (Select All / Deselect All while selecting);
    /// - trailing: Select (Files) or Empty (Trash) as a text button in its own pill, then the
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
        emptyTrashToolbarItem
        if !isSelecting {
            // Keeps the text button (Select / Empty) in a pill of its own, apart from the gear.
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

    /// Trash's Empty button: red text in its own pill, where Select sits on the Files segment.
    /// The confirmation is attached to the button so it anchors there on iPad and Mac.
    @ToolbarContentBuilder
    private var emptyTrashToolbarItem: some ToolbarContent {
        if segment == .trash, !trashed.isEmpty {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Empty", role: .destructive) { isConfirmingEmptyTrash = true }
                    .tint(.red)
                    .accessibilityLabel("Empty Trash")
                    .confirmationDialog(
                        "Empty Trash?",
                        isPresented: $isConfirmingEmptyTrash,
                        titleVisibility: .visible
                    ) {
                        Button("Delete \(trashed.count) Permanently", role: .destructive) {
                            Task { await catalog.emptyTrash() }
                        }
                    } message: {
                        Text("Everything in Trash will be deleted and can't be recovered.")
                    }
            }
        }
    }

    /// This window's menu-command actions, published as a focused-scene value (E7). Acts on the
    /// sidebar's selected file; the pure model decides what is enabled.
    var windowCommands: WindowCommands {
        WindowCommands(
            selectedEntry: selection.flatMap { id in active.first { $0.id == id } },
            canImport: !importCoordinator.isImporting && importCoordinator.pendingDuplicate == nil
                && !isSubscribing,
            importFiles: { isFileImporterPresented = true },
            subscribeToURL: { beginSubscribe() },
            focusSearch: { isSearchFocused = true },
            rename: { beginRename($0) },
            trash: { entry in Task { await catalog.moveToTrash(entry) } }
        )
    }
}
