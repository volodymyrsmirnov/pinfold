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
        }
        CommandMenu("File Actions") {
            fileButtons
        }
        CommandMenu("Place") {
            placeButtons
        }
    }

    @ViewBuilder
    private var fileButtons: some View {
        Button("Rename\u{2026}") { window?.renameSelected() }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!(window?.canRename ?? false))
        Button("Move to Trash") { window?.trashSelected() }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(!(window?.canTrash ?? false))
    }

    @ViewBuilder
    private var placeButtons: some View {
        Button("Toggle Favorite") { place?.toggle() }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(!(place?.canToggleFavorite ?? false))
        Button("Open in Maps") { place?.open() }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(!(place?.canOpenInMaps ?? false))
    }
}
