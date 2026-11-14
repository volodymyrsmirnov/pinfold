import Foundation
@testable import Pinfold
import Testing

/// The pure model behind the per-window menu commands (E7, C8).
@MainActor struct WindowCommandsTests {
    private func entry(name: String, state: CatalogEntry.SidecarState = .ok) -> CatalogEntry {
        CatalogEntry(
            id: UUID(), displayName: name, sourceFilename: "\(name).kml",
            importDate: .now, pointCount: 1, contentSHA256: name,
            storageFolderName: name, sidecarState: state
        )
    }

    private final class Recorder {
        var trashed: [String] = []
        var imports = 0
        var subscribes = 0
        var searches = 0
    }

    private func commands(selected: CatalogEntry?, _ rec: Recorder) -> WindowCommands {
        WindowCommands(
            selectedEntry: selected,
            canImport: true,
            importFiles: { rec.imports += 1 },
            subscribeToURL: { rec.subscribes += 1 },
            focusSearch: { rec.searches += 1 },
            trash: { rec.trashed.append($0.displayName) }
        )
    }

    @Test func actionsAreUnavailableWithoutSelection() {
        let rec = Recorder()
        let cmds = commands(selected: nil, rec)

        #expect(!cmds.canTrash)
        cmds.trashSelected()
        #expect(rec.trashed.isEmpty)
        // Import and Search do not depend on a selection.
        #expect(cmds.canImport)
        cmds.search()
        #expect(rec.searches == 1)
    }

    @Test func trashActsOnTheSelectedEntryOnly() {
        let rec = Recorder()
        let selected = entry(name: "selected")
        _ = entry(name: "other")
        let cmds = commands(selected: selected, rec)

        #expect(cmds.canTrash)
        cmds.trashSelected()

        #expect(rec.trashed == ["selected"])
    }

    @Test func readOnlySelectionDisablesMutations() {
        let rec = Recorder()
        let cmds = commands(selected: entry(name: "bad", state: .unreadable), rec)

        #expect(!cmds.canTrash)
        cmds.trashSelected()
        #expect(rec.trashed.isEmpty)
    }

    @Test func importIsDisabledWhenNotAllowed() {
        let rec = Recorder()
        var cmds = commands(selected: nil, rec)
        cmds.canImport = false
        cmds.importIfAllowed()
        #expect(rec.imports == 0)
    }

    @Test func placeCommandsAreUnavailableWithoutActions() {
        let none = PlaceCommands(toggleFavorite: nil, openInMaps: nil)
        #expect(!none.canToggleFavorite && !none.canOpenInMaps)
        var opened = 0
        let some = PlaceCommands(toggleFavorite: nil, openInMaps: { opened += 1 })
        some.open()
        #expect(some.canOpenInMaps && opened == 1)
    }

    @Test func subscribeCommand_disabledWhileImporting() {
        let rec = Recorder()
        var cmds = commands(selected: nil, rec)
        cmds.subscribeIfAllowed()
        #expect(rec.subscribes == 1)

        cmds.canImport = false
        cmds.subscribeIfAllowed()
        #expect(rec.subscribes == 1)
    }

    // MARK: - Online-list and place commands (2.1)

    private func online(_ name: String, state: CatalogEntry.SidecarState = .ok) throws -> CatalogEntry {
        var entry = entry(name: name, state: state)
        entry.subscription = try Subscription(
            url: #require(URL(string: "https://example.com/\(name).kml")), origin: .url,
            subscribedAt: Date(timeIntervalSince1970: 1)
        )
        return entry
    }

    private func onlineCommands(selected: CatalogEntry?, refreshing: Bool = false) -> WindowCommands {
        var cmds = commands(selected: selected, Recorder())
        cmds.refreshNow = { _ in }
        cmds.copyURL = { _ in }
        cmds.stopUpdating = { _ in }
        cmds.isRefreshingSelection = refreshing
        return cmds
    }

    @Test func onlineSelectionEnablesItsActions() throws {
        let cmds = try onlineCommands(selected: online("list"))
        #expect(cmds.canRefreshNow && cmds.canCopyURL && cmds.canStopUpdating)
    }

    @Test func refreshingDisablesRefreshNowOnly() throws {
        let cmds = try onlineCommands(selected: online("list"), refreshing: true)
        #expect(!cmds.canRefreshNow)
        #expect(cmds.canCopyURL && cmds.canStopUpdating)
    }

    @Test func readOnlyOnlineSelectionOnlyCopiesItsURL() throws {
        let cmds = try onlineCommands(selected: online("list", state: .unreadable))
        #expect(!cmds.canRefreshNow && !cmds.canStopUpdating)
        #expect(cmds.canCopyURL)
    }

    @Test func localFileHasNoOnlineActions() {
        let cmds = onlineCommands(selected: entry(name: "local"))
        #expect(!cmds.canRefreshNow && !cmds.canCopyURL && !cmds.canStopUpdating)
    }

    @Test func placeCommandTitlesFollowState() {
        var place = PlaceCommands()
        #expect(place.favoriteTitle == "Add to Favorites")
        #expect(place.visitedTitle == "Mark as Seen")
        place.isFavorite = true
        place.isVisited = true
        #expect(place.favoriteTitle == "Remove from Favorites")
        #expect(place.visitedTitle == "Mark as Unseen")
    }
}
