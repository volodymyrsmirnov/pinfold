import Foundation
import os

/// Download bookkeeping for one entry's `resources/` directory, persisted as
/// `download-state.json` (local-only, never synced).
struct DownloadState: Equatable {
    /// Per-href retry state.
    struct HrefState: Codable, Equatable {
        /// Failed attempts so far (drives the backoff).
        var attempts: Int
        /// Earliest time the next attempt may start; `nil` means "any time".
        var nextAttemptAt: Date?
        /// How many 2xx responses were not images (captive portals); only these count toward
        /// the permanent skip.
        var nonImageResponses = 0

        init(attempts: Int, nextAttemptAt: Date?, nonImageResponses: Int = 0) {
            self.attempts = attempts
            self.nextAttemptAt = nextAttemptAt
            self.nonImageResponses = nonImageResponses
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            attempts = try container.decode(Int.self, forKey: .attempts)
            nextAttemptAt = try container.decodeIfPresent(Date.self, forKey: .nextAttemptAt)
            nonImageResponses = try container.decodeIfPresent(Int.self, forKey: .nonImageResponses) ?? 0
        }
    }

    /// Failed-download state, keyed by the original href. An href that downloaded
    /// successfully (or was permanently skipped) has no entry.
    var hrefs: [String: HrefState] = [:]
    /// The user allowed this entry's remote images under the `.ask` policy (DL-3).
    var consent = false
    /// Reserved for wave 2 (CACHE, C9): downloads for this entry wait until it is opened.
    var deferredUntilOpened = false
}

extension DownloadState: Codable {
    private enum CodingKeys: String, CodingKey {
        case hrefs, consent, deferredUntilOpened
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hrefs = try container.decodeIfPresent([String: HrefState].self, forKey: .hrefs) ?? [:]
        consent = try container.decodeIfPresent(Bool.self, forKey: .consent) ?? false
        deferredUntilOpened = try container.decodeIfPresent(Bool.self, forKey: .deferredUntilOpened) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hrefs, forKey: .hrefs)
        try container.encode(consent, forKey: .consent)
        try container.encode(deferredUntilOpened, forKey: .deferredUntilOpened)
    }
}

/// The only reader and writer of an entry's `manifest.json`, `remote-hrefs.json` and
/// `download-state.json`.
///
/// Every read-modify-write runs under a lock held per `resources/` directory, so concurrent
/// download passes (or an import racing a retry) never lose each other's entries. The API is
/// deliberately synchronous (not an actor) because `ResourceCache.localURL(forHref:in:)` and
/// `writeEmbedded` are called from synchronous code; the critical sections are small file
/// operations and never span an `await`. Writes are atomic, so unlocked readers can never
/// observe a torn file either.
///
/// Missing or undecodable files read as empty. Wave 2 (CACHE) adds `deferredUntilOpened`
/// handling through `updateState(in:_:)`.
final class ResourceManifestStore: Sendable {
    /// The process-wide store; every `ResourceCache` uses it so locks are shared.
    static let shared = ResourceManifestStore()

    /// The download-state file. It holds the person's remote-image consent, so a refresh keeps it.
    static let stateFilename = "download-state.json"

    private let locks = OSAllocatedUnfairLock<[String: NSLock]>(initialState: [:])

    // MARK: - Locking

    /// Runs `body` while holding the lock for `dir`. Not re-entrant: do not nest calls for
    /// the same directory.
    private func withLock<T>(_ dir: URL, _ body: () throws -> T) rethrows -> T {
        let key = dir.standardizedFileURL.path
        let lock = locks.withLock { table -> NSLock in
            if let existing = table[key] {
                return existing
            }
            let created = NSLock()
            table[key] = created
            return created
        }
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: - Manifest (href to cached filename; empty filename = permanent skip)

    /// The href-to-filename manifest.
    func manifest(in dir: URL) -> [String: String] {
        withLock(dir) { read([String: String].self, "manifest.json", in: dir) ?? [:] }
    }

    /// Atomically mutates the manifest. Skips the write when `body` changes nothing.
    func updateManifest(in dir: URL, _ body: (inout [String: String]) -> Void) throws {
        try withLock(dir) {
            let old = read([String: String].self, "manifest.json", in: dir) ?? [:]
            var new = old
            body(&new)
            if new != old || !fileExists("manifest.json", in: dir) {
                try write(new, "manifest.json", in: dir)
            }
        }
    }

    // MARK: - Recorded remote hrefs

    /// The remote hrefs recorded at download time (sorted).
    func recordedHrefs(in dir: URL) -> [String] {
        withLock(dir) { read([String].self, "remote-hrefs.json", in: dir) ?? [] }
    }

    /// Merges `hrefs` into the recorded set. No write when nothing is new.
    func recordHrefs(_ hrefs: [String], in dir: URL) {
        guard !hrefs.isEmpty else { return }
        withLock(dir) {
            let existing = Set(read([String].self, "remote-hrefs.json", in: dir) ?? [])
            let merged = existing.union(hrefs)
            guard merged != existing else { return }
            try? write(merged.sorted(), "remote-hrefs.json", in: dir)
        }
    }

    // MARK: - Download state

    /// The current download state (defaults when the file is absent).
    func state(in dir: URL) -> DownloadState {
        withLock(dir) { read(DownloadState.self, Self.stateFilename, in: dir) ?? DownloadState() }
    }

    /// Atomically mutates the download state. Writes only when the state changed.
    func updateState(in dir: URL, _ body: (inout DownloadState) -> Void) {
        withLock(dir) {
            let old = read(DownloadState.self, Self.stateFilename, in: dir) ?? DownloadState()
            var new = old
            body(&new)
            guard new != old else { return }
            try? write(new, Self.stateFilename, in: dir)
        }
    }

    // MARK: - Disk helpers (call only under the lock)

    private func fileExists(_ name: String, in dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
    }

    private func read<T: Decodable>(_ type: T.Type, _ name: String, in dir: URL) -> T? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    private func write(_ value: some Encodable, _ name: String, in dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: dir.appendingPathComponent(name), options: .atomic)
    }
}
