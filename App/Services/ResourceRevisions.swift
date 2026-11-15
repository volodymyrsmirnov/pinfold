import Foundation
import Observation
import os

/// Tells the UI that an entry's cached resources changed on disk, so a view that resolved an
/// icon or photo before it was downloaded (or after it was cleared) resolves it again.
///
/// Views resolve images synchronously through `ResourceCache.localURL(forHref:in:)`, which is
/// not observable. A view that shows cached resources reads `revision(for:)` for the entry's
/// `resources/` directory in its `body`; `ResourceManifestStore` calls `noteChange(in:)` after
/// every manifest write (a download landing, a permanent skip, a clear), and the bump re-renders
/// exactly the views of that entry. Bumps are coalesced so a pass of hundreds of downloads
/// re-renders a few times a second, not once per image.
@MainActor
final class ResourceRevisions {
    static let shared = ResourceRevisions()

    /// One observable counter per directory, so a bump re-renders only that entry's views.
    @Observable
    final class Counter {
        var value = 0
    }

    private var counters: [String: Counter] = [:]

    /// How long changes are gathered before the views are told.
    nonisolated static let coalescingDelay: Duration = .milliseconds(250)

    /// Directories changed since the last flush, and whether a flush is already scheduled.
    private nonisolated static let pending = OSAllocatedUnfairLock(
        initialState: (dirs: Set<String>(), scheduled: false)
    )

    /// The current revision of `resourcesDir`. Reading it in a view's `body` subscribes the view
    /// to that directory's changes.
    func revision(for resourcesDir: URL) -> Int {
        counter(for: Self.key(resourcesDir)).value
    }

    /// Bumps the revisions of `dirs` at once (the flush of `noteChange(in:)`; tests call it
    /// directly).
    func bump(_ keys: Set<String>) {
        for key in keys {
            counter(for: key).value &+= 1
        }
    }

    /// Records that `resourcesDir`'s cached resources changed. Callable from any thread; the
    /// views are told on the main actor after `coalescingDelay`.
    nonisolated static func noteChange(in resourcesDir: URL) {
        let key = key(resourcesDir)
        let shouldSchedule = pending.withLock { state in
            state.dirs.insert(key)
            guard !state.scheduled else { return false }
            state.scheduled = true
            return true
        }
        guard shouldSchedule else { return }
        Task { @MainActor in
            try? await Task.sleep(for: coalescingDelay)
            let dirs = pending.withLock { state in
                defer { state = (dirs: [], scheduled: false) }
                return state.dirs
            }
            shared.bump(dirs)
        }
    }

    private func counter(for key: String) -> Counter {
        if let existing = counters[key] {
            return existing
        }
        let created = Counter()
        counters[key] = created
        return created
    }

    nonisolated static func key(_ resourcesDir: URL) -> String {
        resourcesDir.standardizedFileURL.path
    }
}

extension ResourceCache {
    /// `localURL(forHref:in:)` for a view's `body`: also subscribes the view to the entry's
    /// `ResourceRevisions`, so an image that is downloaded (or cleared) after the view first
    /// rendered shows up (or goes) without leaving the screen.
    @MainActor
    func observedLocalURL(forHref href: String, in resourcesDir: URL) -> URL? {
        _ = ResourceRevisions.shared.revision(for: resourcesDir)
        return localURL(forHref: href, in: resourcesDir)
    }
}
