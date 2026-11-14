import SwiftUI

/// The menu-bar actions of ONE window, published as a focused-scene value (E7).
///
/// The old `AppCommands` was a single object shared by every window of the `WindowGroup`, so
/// one ⌘I or ⌘F fired in every open window. A focused-scene value is published per window and
/// the menu reads the focused window's copy, so a command acts on that window only and
/// disables itself when no window (or no selection) supplies one. Pure value type: the
/// enablement rules are unit-tested without any UI.
struct WindowCommands {
    /// The file selected in the sidebar, if any.
    let selectedEntry: CatalogEntry?
    /// Whether importing is allowed right now (not while an import stalls on a prompt).
    var canImport: Bool
    let importFiles: () -> Void
    /// Opens the "Remote URL" alert; gated by `canImport` like importing.
    let subscribeToURL: () -> Void
    let focusSearch: () -> Void
    let rename: (CatalogEntry) -> Void
    let trash: (CatalogEntry) -> Void

    /// The selection when it may be changed; read-only entries (B12) are excluded.
    private var editableSelection: CatalogEntry? {
        guard let selectedEntry, !selectedEntry.isReadOnly else { return nil }
        return selectedEntry
    }

    var canRename: Bool {
        editableSelection != nil
    }

    var canTrash: Bool {
        editableSelection != nil
    }

    func importIfAllowed() {
        if canImport {
            importFiles()
        }
    }

    func subscribeIfAllowed() {
        if canImport {
            subscribeToURL()
        }
    }

    func search() {
        focusSearch()
    }

    func renameSelected() {
        if let entry = editableSelection {
            rename(entry)
        }
    }

    func trashSelected() {
        if let entry = editableSelection {
            trash(entry)
        }
    }
}

/// The menu-bar actions for the place open in a window's detail column, published by
/// `PlacemarkDetailView` as a focused-scene value. Absent whenever no place is open.
struct PlaceCommands {
    /// `nil` when the favourites store is unavailable.
    let toggleFavorite: (() -> Void)?
    /// `nil` when the place has no coordinate.
    let openInMaps: (() -> Void)?

    var canToggleFavorite: Bool {
        toggleFavorite != nil
    }

    var canOpenInMaps: Bool {
        openInMaps != nil
    }

    func toggle() {
        toggleFavorite?()
    }

    func open() {
        openInMaps?()
    }
}

/// ⌘F for the file open on top of a window's detail column, published by `KMLDetailView` while
/// it is on screen: focuses that file's search bar instead of the catalogue's.
struct FileSearchCommand {
    let focus: () -> Void
}

extension FocusedValues {
    @Entry var windowCommands: WindowCommands?
    @Entry var placeCommands: PlaceCommands?
    @Entry var fileSearch: FileSearchCommand?
}
