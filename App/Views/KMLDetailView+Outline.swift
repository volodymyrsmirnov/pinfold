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
        /// The content hash of the published document: an online refresh swaps the document
        /// without ever unloading it, and the new one must be shown even with no search active.
        let documentSHA: String?
        let collapsed: Set<String>
        let nearestFirst: Bool
        /// Flips when the search index lands (or is reset), so an active search rebuilds with it.
        let corpusReady: Bool
        /// Notes revision, only while a search is active (0 otherwise), so editing a note
        /// re-runs a live search without a rebuild when a search starts or ends.
        let notesRevision: Int
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

    /// Whether a non-blank search is active.
    var isSearchActive: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Note texts to search, only while a search is active.
    var searchNoteTexts: [String: String] {
        guard isSearchActive else { return [:] }
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
        outlineQuery = query.trimmingCharacters(in: .whitespaces)
        outlineGeneration += 1
    }
}

extension KMLDetailView {
    /// (Re)builds the search corpus for the loaded document. Re-runs on every pop back from a
    /// placemark, so the corpus is kept for the same document: matches must not vanish and
    /// reappear mid-search.
    func refreshSearchCorpus() async {
        if searchCorpus != nil, let document, searchCorpusDocument == document {
            return
        }
        searchCorpus = nil
        searchCorpusDocument = nil
        guard let document else { return }
        let corpus = await makeSearchCorpus(root: document.root)
        if Task.isCancelled {
            return
        }
        searchCorpus = corpus
        searchCorpusDocument = document
    }
}

/// Builds a `SearchCorpus` on a background task (kept out of the view's isolation; see the
/// `ClosureLifetimeFixup` note in CLAUDE.md).
nonisolated func makeSearchCorpus(root: KMLContainer) async -> SearchCorpus {
    await Task.detached(priority: .utility) {
        SearchCorpus(root: root)
    }.value
}

// Walks the document into an outline on a background task.
// swiftlint:disable:next function_parameter_count
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
