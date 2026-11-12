import SwiftUI

extension HomeView {
    /// The catalogue toolbar: import, favorites, sort (Files only), settings, and the import
    /// progress status in the bottom bar. Kept out of `body` to keep its type-checking small.
    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                isFileImporterPresented = true
            } label: {
                Label("Import", systemImage: "plus")
            }
            // While an import is in flight, the button is disabled and a progress
            // indicator (below) takes its visual place — re-tapping mid-import is a no-op
            // anyway (the picker just enqueues more), but the spinner signals work is on.
            // Also disabled while a duplicate alert stalls the queue: the coordinator is
            // waiting on the user's decision, so offering more imports would contradict
            // the stalled state (queued URLs are kept either way).
            .disabled(importCoordinator.isImporting || importCoordinator.pendingDuplicate != nil)
        }
        // Import progress: a spinner plus the current filename, shown only while the
        // coordinator is draining its queue (e.g. a large KMZ that takes a moment).
        // Placed in the bottom bar (`.bottomBar`) rather than `.principal`: a principal
        // item REPLACES the navigation title on compact width, which made the "Pinfold"
        // title vanish mid-import. The status bar floats below the list and leaves the
        // title intact on every size class.
        if importCoordinator.isImporting {
            ToolbarItem(placement: .bottomBar) {
                ImportProgressLabel(filename: importCoordinator.currentFilename)
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

    /// A `Binding` to the persisted sort preference for the toolbar `Picker`. Built manually
    /// (rather than via `@Bindable`) so the `@Observable` `AppSettings` read from the
    /// environment can be bound without re-declaring it as a bindable property.
    var sortBinding: Binding<EntrySort> {
        Binding(get: { settings.entrySort }, set: { settings.entrySort = $0 })
    }
}
