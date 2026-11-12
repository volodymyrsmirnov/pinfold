import CoreLocation
import PinfoldCore
import SwiftUI

extension KMLDetailView {
    // MARK: - Outline rebuild

    /// Identity for the un-debounced outline rebuild `.task`: the document (id + loaded
    /// flag, since the document arrives asynchronously after first appearance) and the
    /// collapse set. The search text deliberately lives in its own debounced trigger.
    struct ImmediateOutlineTrigger: Equatable {
        let documentID: CatalogEntry.ID
        let documentLoaded: Bool
        let collapsed: Set<String>
        let nearestFirst: Bool
        /// Flips when the search index lands (or is reset), so an active search rebuilds with it.
        let corpusReady: Bool
        /// Note texts, only while a search is active (empty otherwise), so editing a note
        /// re-runs a live search without rebuilding for unrelated note edits.
        let noteTexts: [String: String]
        let locationLat: Double?
        let locationLon: Double?
    }

    /// The sort to build the outline with: `.nearest` only when the user chose it AND a location
    /// fix is available; otherwise `.document`. Computed on the main actor (reads `locationAuth`)
    /// and passed into the detached build, which takes a plain `Sendable` value.
    var effectiveSort: PlacemarkOutline.Sort {
        if nearestFirst, let location = locationAuth.lastLocation {
            return .nearest(location)
        }
        return .document
    }

    /// Note texts to search, only while a search is active.
    var searchNoteTexts: [String: String] {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return [:] }
        return annotations?.noteTextsByKey ?? [:]
    }

    /// Rebuilds `outline` from the live `searchText`/`collapsedFolderIDs` immediately
    /// (debouncing is the caller's concern). Cancel-safe: the result is discarded if the
    /// owning `.task` was superseded. The walk runs in a detached task because
    /// `KMLContainer`/`KMLPlacemark` are `Sendable` value types.
    func buildOutlineNow() async {
        guard let document else { return }
        let query = searchText
        let collapsed = collapsedFolderIDs
        let root = document.root
        let sort = effectiveSort
        let corpus = searchCorpus
        let notes = searchNoteTexts
        let built = await buildOutlineOffMain(
            root: root, query: query, collapsed: collapsed, sort: sort, corpus: corpus, notes: notes
        )
        if Task.isCancelled {
            return
        }
        outline = built
        outlineGeneration += 1
    }
}

/// Builds a `SearchCorpus` on a background task (kept out of the view's isolation; see the
/// `ClosureLifetimeFixup` note in CLAUDE.md).
nonisolated func makeSearchCorpus(root: KMLContainer) async -> SearchCorpus {
    await Task.detached(priority: .utility) {
        SearchCorpus(root: root)
    }.value
}

/// Walks the document into an outline on a background task.
// swiftlint:disable:next function_parameter_count -- mirrors PlacemarkOutline.build inputs
nonisolated func buildOutlineOffMain(
    root: KMLContainer, query: String, collapsed: Set<String>,
    sort: PlacemarkOutline.Sort, corpus: SearchCorpus?, notes: [String: String]
) async -> PlacemarkOutline {
    await Task.detached(priority: .userInitiated) {
        PlacemarkOutline.build(
            from: root, matching: query, collapsed: collapsed, sort: sort, corpus: corpus, notes: notes
        )
    }.value
}
