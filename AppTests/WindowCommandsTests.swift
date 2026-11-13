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
        var renamed: [String] = []
        var tagged: [String] = []
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
            rename: { rec.renamed.append($0.displayName) },
            editTags: { rec.tagged.append($0.displayName) },
            trash: { rec.trashed.append($0.displayName) }
        )
    }

    @Test func actionsAreUnavailableWithoutSelection() {
        let rec = Recorder()
        let cmds = commands(selected: nil, rec)

        #expect(!cmds.canRename)
        #expect(!cmds.canEditTags)
        #expect(!cmds.canTrash)
        cmds.renameSelected()
        cmds.editTagsOfSelected()
        cmds.trashSelected()
        #expect(rec.renamed.isEmpty && rec.tagged.isEmpty && rec.trashed.isEmpty)
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

        #expect(!cmds.canRename && !cmds.canEditTags && !cmds.canTrash)
        cmds.trashSelected()
        cmds.renameSelected()
        #expect(rec.trashed.isEmpty && rec.renamed.isEmpty)
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
}
