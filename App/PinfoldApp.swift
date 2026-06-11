import SwiftUI

@main
struct PinfoldApp: App {
    /// Bridges the "Import…" menu command to `HomeView`'s file importer (see `AppCommands`).
    @State private var appCommands = AppCommands()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appCommands)
        }
        .commands {
            // ⌘I mirrors HomeView's "+" toolbar button. Placed after the standard "New"
            // group so it sits with the file-creation commands in the menu bar (Mac /
            // hardware-keyboard iPad). The flag-bump is observed by HomeView, which owns
            // the fileImporter — Commands can't present sheets directly.
            CommandGroup(after: .newItem) {
                Button("Import\u{2026}") {
                    appCommands.requestImport()
                }
                .keyboardShortcut("i", modifiers: .command)
            }
            // ⌘F focuses HomeView's catalogue search field. Like ⌘I it bumps a counter on
            // AppCommands (Commands can't move focus directly); HomeView observes it and
            // drives its `.searchFocused` binding. Placed in `.textEditing` so it sits with
            // the standard Find commands in the menu bar.
            CommandGroup(after: .textEditing) {
                Button("Search") {
                    appCommands.requestSearchFocus()
                }
                .keyboardShortcut("f", modifiers: .command)
            }
        }
    }
}
