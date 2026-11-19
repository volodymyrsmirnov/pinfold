import Foundation
import os

/// Where a remote image stands, for the placeholder a view shows until it is on disk.
enum RemoteImageStatus: Equatable {
    /// Downloaded: the cached file.
    case cached(URL)
    /// Queued or downloading in the current pass.
    case loading
    /// The last attempt this session failed (offline, server error, not an image); a later pass
    /// may still fetch it.
    case failed
    /// Not fetched and nothing running: not attempted yet this session, or not allowed (policy,
    /// consent, cleared).
    case idle
}

/// Which remote images are being downloaded, and which failed, this session. In memory only:
/// the persisted `download-state.json` keeps the backoff, this keeps what the UI needs to tell
/// "working" from "stuck" without reading files in a view's `body`.
///
/// Every change bumps the entry's `ResourceRevisions`, so placeholders update.
enum ResourceActivity {
    private struct Entry {
        var active: Set<String> = []
        var failed: Set<String> = []
    }

    private static let entries = OSAllocatedUnfairLock<[String: Entry]>(initialState: [:])

    /// Marks `hrefs` as queued for download and returns those this caller now owns: hrefs
    /// already queued or downloading (by another pass over the same entry) are left out.
    static func claim(_ hrefs: [String], in resourcesDir: URL) -> [String] {
        var claimed: [String] = []
        update(resourcesDir) { entry in
            for href in hrefs where entry.active.insert(href).inserted {
                claimed.append(href)
            }
        }
        return claimed
    }

    /// Forgets the failures of hrefs not in `hrefs` (the entry no longer has them).
    static func retainFailures(_ hrefs: Set<String>, in resourcesDir: URL) {
        update(resourcesDir) { $0.failed.formIntersection(hrefs) }
    }

    /// Marks `href` as no longer downloading; `failed` records how its attempt ended.
    static func end(_ href: String, failed: Bool, in resourcesDir: URL) {
        update(resourcesDir) { entry in
            entry.active.remove(href)
            if failed {
                entry.failed.insert(href)
            } else {
                entry.failed.remove(href)
            }
        }
    }

    /// Unmarks queued hrefs that were never started (the pass stopped early).
    static func cancel(_ hrefs: some Sequence<String>, in resourcesDir: URL) {
        update(resourcesDir) { entry in
            for href in hrefs {
                entry.active.remove(href)
            }
        }
    }

    /// Forgets the failures of `resourcesDir` (its downloads were cleared).
    static func reset(in resourcesDir: URL) {
        update(resourcesDir) { $0.failed.removeAll() }
    }

    static func isActive(_ href: String, in resourcesDir: URL) -> Bool {
        entries.withLock { $0[ResourceRevisions.key(resourcesDir)]?.active.contains(href) ?? false }
    }

    static func hasFailed(_ href: String, in resourcesDir: URL) -> Bool {
        entries.withLock { $0[ResourceRevisions.key(resourcesDir)]?.failed.contains(href) ?? false }
    }

    private static func update(_ resourcesDir: URL, _ body: (inout Entry) -> Void) {
        let key = ResourceRevisions.key(resourcesDir)
        let changed = entries.withLockUnchecked { table in
            var entry = table[key] ?? Entry()
            let before = (entry.active, entry.failed)
            body(&entry)
            table[key] = entry.active.isEmpty && entry.failed.isEmpty ? nil : entry
            return before != (entry.active, entry.failed)
        }
        if changed {
            ResourceRevisions.noteChange(in: resourcesDir)
        }
    }
}

extension ResourceCache {
    /// Where `href`'s image stands, for a view's `body`; subscribes the view to the entry's
    /// `ResourceRevisions`, so the placeholder follows the download.
    @MainActor
    func observedImageStatus(forHref href: String, in resourcesDir: URL) -> RemoteImageStatus {
        if let url = observedLocalURL(forHref: href, in: resourcesDir) {
            return .cached(url)
        }
        if ResourceActivity.isActive(href, in: resourcesDir) {
            return .loading
        }
        return ResourceActivity.hasFailed(href, in: resourcesDir) ? .failed : .idle
    }
}
