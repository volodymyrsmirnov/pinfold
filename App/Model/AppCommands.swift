import SwiftUI

/// The app's menu-bar / hardware-keyboard commands.
///
/// Each command reads the FOCUSED window's `WindowCommands` / `PlaceCommands` (published with
/// `focusedSceneValue`), so it acts on that window only and disables itself when nothing
/// supplies one — a file-level command with no selection, a place command with no place open.
/// This replaces the former app-wide counter object, which fired in every open window (E7).
struct AppCommands: Commands {
    @FocusedValue(\.windowCommands) private var window
    @FocusedValue(\.placeCommands) private var place
    @FocusedValue(\.fileSearch) private var fileSearch

    var body: some Commands {
        // Placed after the standard "New" group so Import sits with file-creation commands.
        CommandGroup(after: .newItem) {
            Button("Import Local File\u{2026}") { window?.importIfAllowed() }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(!(window?.canImport ?? false))
            Button("Import Remote URL\u{2026}") { window?.subscribeIfAllowed() }
                .disabled(!(window?.canImport ?? false))
        }
        CommandGroup(after: .textEditing) {
            // The open file's search when a file is on screen, else the catalogue's.
            Button("Search") {
                if let fileSearch {
                    fileSearch.focus()
                } else {
                    window?.search()
                }
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(window == nil && fileSearch == nil)
            // Mail's ⌥⌘F: the catalogue-wide search, even while a file is open beside it.
            Button("Search All Files") { window?.search() }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(window == nil)
        }
        CommandMenu("File Actions") {
            fileButtons
        }
        CommandMenu("Place") {
            placeButtons
        }
    }

    /// The selected file's actions, in the order of its row menu: the online-list group, then
    /// Archive. Share isn't here: a
    /// menu-bar command can't present the share sheet.
    @ViewBuilder
    private var fileButtons: some View {
        Section {
            Button("Refresh Now") { window?.refreshSelected() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!(window?.canRefreshNow ?? false))
            Button("Copy URL") { window?.copySelectedURL() }
                .disabled(!(window?.canCopyURL ?? false))
            Button("Stop Updating\u{2026}") { window?.stopUpdatingSelected() }
                .disabled(!(window?.canStopUpdating ?? false))
        }
        Section {
            Button("Archive") { window?.trashSelected() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!(window?.canTrash ?? false))
        }
    }

    /// The open place's actions, in the order of its "⋯" menu (`PlacemarkActions`), with Open
    /// in Maps — the place screen's primary button — first. Share isn't here: a menu-bar
    /// command can't present the share sheet.
    @ViewBuilder
    private var placeButtons: some View {
        Section {
            Button("Open in Maps") { place?.open() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(!(place?.canOpenInMaps ?? false))
            Button("Show on Map") { place?.showOnMap?() }
                .disabled(place?.showOnMap == nil)
        }
        Section {
            Button(place?.favoriteTitle ?? String(localized: "Add to Favorites")) { place?.toggle() }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(!(place?.canToggleFavorite ?? false))
            Button(place?.visitedTitle ?? String(localized: "Mark as Seen")) { place?.toggleVisited?() }
                .disabled(place?.toggleVisited == nil)
        }
        Section {
            Button("Copy Coordinates") { place?.copyCoordinates?() }
                .disabled(place?.copyCoordinates == nil)
            Button("Copy Name") { place?.copyName?() }
                .disabled(place?.copyName == nil)
        }
    }
}
