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

    /// The error worth showing for a failed load, or `nil` for a cancellation (the person left
    /// the screen; nothing went wrong).
    static func reportableError(_ error: Error) -> Error? {
        error is CancellationError ? nil : error
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
