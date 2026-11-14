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
    let trash: (CatalogEntry) -> Void
    /// Online-list actions for the selection (Refresh Now, Copy URL, Stop Updating), as in the
    /// file's row and "⋯" menus. `nil` where the window doesn't supply them.
    var refreshNow: ((CatalogEntry) -> Void)?
    var copyURL: ((CatalogEntry) -> Void)?
    var stopUpdating: ((CatalogEntry) -> Void)?
    /// Whether the selected online list is refreshing right now (Refresh Now is then disabled).
    var isRefreshingSelection = false

    /// The selection when it may be changed; read-only entries (B12) are excluded.
    private var editableSelection: CatalogEntry? {
        guard let selectedEntry, !selectedEntry.isReadOnly else { return nil }
        return selectedEntry
    }

    var canTrash: Bool {
        editableSelection != nil
    }

    /// The selection when it is an online list (whatever its sidecar state).
    private var onlineSelection: CatalogEntry? {
        guard let selectedEntry, selectedEntry.subscription != nil else { return nil }
        return selectedEntry
    }

    var canRefreshNow: Bool {
        refreshNow != nil && editableSelection?.subscription != nil && !isRefreshingSelection
    }

    var canCopyURL: Bool {
        copyURL != nil && onlineSelection != nil
    }

    var canStopUpdating: Bool {
        stopUpdating != nil && editableSelection?.subscription != nil
    }

    func refreshSelected() {
        if canRefreshNow, let entry = editableSelection {
            refreshNow?(entry)
        }
    }

    func copySelectedURL() {
        if let entry = onlineSelection {
            copyURL?(entry)
        }
    }

    func stopUpdatingSelected() {
        if canStopUpdating, let entry = editableSelection {
            stopUpdating?(entry)
        }
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

    func trashSelected() {
        if let entry = editableSelection {
            trash(entry)
        }
    }
}

/// The menu-bar actions for the place open in a window's detail column, published by
/// `PlacemarkDetailView` as a focused-scene value. Absent whenever no place is open. Mirrors the
/// place's "⋯" menu (`PlacemarkActions`), minus Share, which a menu-bar command can't present.
struct PlaceCommands {
    /// `nil` when favourites are unavailable or the file can't be written.
    var toggleFavorite: (() -> Void)?
    var isFavorite = false
    /// `nil` when favourites are unavailable or the file can't be written.
    var toggleVisited: (() -> Void)?
    var isVisited = false
    /// `nil` when the place has no coordinate.
    var openInMaps: (() -> Void)?
    /// `nil` when the place has no coordinate.
    var showOnMap: (() -> Void)?
    /// `nil` when the place has no coordinate.
    var copyCoordinates: (() -> Void)?
    var copyName: (() -> Void)?

    var canToggleFavorite: Bool {
        toggleFavorite != nil
    }

    var canOpenInMaps: Bool {
        openInMaps != nil
    }

    /// "Add to Favorites" / "Remove from Favorites", as in the place's menus.
    var favoriteTitle: String {
        isFavorite ? String(localized: "Remove from Favorites") : String(localized: "Add to Favorites")
    }

    /// "Mark as Seen" / "Mark as Unseen", as in the place's menus.
    var visitedTitle: String {
        isVisited ? String(localized: "Mark as Unseen") : String(localized: "Mark as Seen")
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
