import SwiftUI

extension HomeView {
    /// The catalogue toolbar: import, favorites, sort (Files only), settings, and the import
    /// progress status in the bottom bar. Kept out of `body` to keep its type-checking small.
    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Button("Choose File\u{2026}", systemImage: "doc") {
                    isFileImporterPresented = true
                }
                Button("Subscribe to URL\u{2026}", systemImage: "globe") {
                    beginSubscribe()
                }
                .disabled(isSubscribing)
            } label: {
                Label("Import", systemImage: "plus")
            }
            // While an import is in flight, the button is disabled and a progress
            // indicator (below) takes its visual place — re-tapping mid-import is a no-op
            // anyway (the picker just enqueues more), but the spinner signals work is on.
            // Also disabled while a duplicate alert stalls the queue: the coordinator is
            // waiting on the user's decision, so offering more imports would contradict
            // the stalled state (queued URLs are kept either way).
            .disabled(importCoordinator.isImporting || importCoordinator.pendingDuplicate != nil || isSubscribing)
        }
        selectToolbarItem
        selectBottomBar
        // Import progress: a spinner plus the current filename, shown only while the
        // coordinator is draining its queue (e.g. a large KMZ that takes a moment).
        // Placed in the bottom bar (`.bottomBar`) rather than `.principal`: a principal
        // item REPLACES the navigation title on compact width, which made the "Pinfold"
        // title vanish mid-import. The status bar floats below the list and leaves the
        // title intact on every size class. Hidden while select mode owns the bottom bar
        // (Tag / Trash): the two would crowd each other, and the top-bar import button is
        // already disabled during an import.
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
        // Favorites — the consolidated, catalogue-wide starred-placemarks sheet. Leads the
        // trailing group (before sort/gear); shown on both segments since favorites span
        // every file, not just the current segment's.
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                isFavoritesPresented = true
            } label: {
                Label("Favorites", systemImage: "star")
            }
        }
        // Sort menu — Files segment only (Trash keeps its trashed-date order). Sits next to
        // the gear in the trailing group rather than `.principal`, so it never replaces the
        // navigation title. The Picker drives `settings.entrySort`, which `sortedActive`
        // applies at render time (presentation-level; storage order is untouched).
        if segment == .files {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort By", selection: sortBinding) {
                        ForEach(EntrySort.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                isSettingsPresented = true
            } label: {
                Label("Settings", systemImage: "gear")
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
            editTags: { beginEditTags($0) },
            trash: { entry in Task { await catalog.moveToTrash(entry) } }
        )
    }

    /// A `Binding` to the persisted sort preference for the toolbar `Picker`. Built manually
    /// (rather than via `@Bindable`) so the `@Observable` `AppSettings` read from the
    /// environment can be bound without re-declaring it as a bindable property.
    var sortBinding: Binding<EntrySort> {
        Binding(get: { settings.entrySort }, set: { settings.entrySort = $0 })
    }
}
