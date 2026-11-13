import Foundation
import PinfoldCore

/// Off-main document loading for `KMLDetailView.loadDocument`, kept in free functions so the
/// detached closures are compiled outside the view's SIL (see the `ClosureLifetimeFixup` note
/// in FavoritesView.swift).
enum DocumentLoad {
    /// Parses only the document. Unlike `KMLReader.read` this never inflates a KMZ's resources
    /// into memory, so a large photo KMZ cannot exhaust it on open. Throws `CancellationError`
    /// when the calling task is cancelled mid-parse.
    static func parse(_ data: Data) throws -> KMLDocument {
        try KMLReader.readDocument(data: data)
    }

    /// What keys the open list's content reload: the entry and its live content hash. A change
    /// to either restarts (and so cancels) the reload in flight.
    struct ContentKey: Equatable {
        let entryID: UUID
        let sha: String
    }

    /// What the open list does about the live content hash.
    enum ContentAction: Equatable {
        /// The document shown is the live content.
        case keep
        /// The first load is still running; it reconciles with the live hash when it finishes.
        case waitForInitialLoad
        /// An online refresh replaced the original: re-read it.
        case reload
    }

    /// `loadedSHA` is the hash of the content `document` was parsed from, set only together
    /// with a successfully published document.
    static func contentAction(loadedSHA: String?, live: String, documentLoaded: Bool) -> ContentAction {
        guard documentLoaded else { return .waitForInitialLoad }
        return loadedSHA == live ? .keep : .reload
    }

    /// The error worth showing for a failed load, or `nil` for a cancellation (the person left
    /// the screen; nothing went wrong).
    static func reportableError(_ error: Error) -> Error? {
        error is CancellationError ? nil : error
    }

    /// The error to show for a failed load: `nil` while a document is still on screen (an
    /// in-place reload after a refresh keeps the working list rather than replacing it with
    /// "Cannot Open File"), else `reportableError`.
    static func failureToShow(_ error: Error, documentShown: Bool) -> Error? {
        documentShown ? nil : reportableError(error)
    }

    /// Orders the open list's document loads. The first load, its reconcile, the content-keyed
    /// reload and a replaced network-link original each take a ticket when they start, and
    /// only the newest may publish (or report an error), so an older parse that finishes last
    /// never overwrites a newer document.
    struct Tickets {
        private(set) var latest = 0

        mutating func issue() -> Int {
            latest &+= 1
            return latest
        }

        func isCurrent(_ ticket: Int) -> Bool {
            ticket == latest
        }
    }
}

/// Reads (materializing an iCloud placeholder first) and parses `fileURL` off the main actor.
/// Cancelling the caller cancels the detached parse.
func loadDocumentOffMain(_ fileURL: URL) async throws -> KMLDocument {
    let task = Task.detached(priority: .userInitiated) {
        let data = try UbiquityContainer.readDownloadingIfNeeded(fileURL)
        return try DocumentLoad.parse(data)
    }
    return try await withTaskCancellationHandler {
        try await task.value
    } onCancel: {
        task.cancel()
    }
}

/// Clears the "cleared by the user" deferral for this entry and fetches its recorded hrefs, in
/// the background so opening never waits on the network.
func resumeDeferredDownloads(_ cache: ResourceCache, in resourcesDir: URL) {
    Task.detached(priority: .utility) {
        await cache.resumeDeferred(in: resourcesDir)
    }
}
