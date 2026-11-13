import Foundation
import Observation

// MARK: - ImportCoordinator

/// The one import queue behind every arrival path: the in-app file picker, "Open in Pinfold"
/// (the opened file and the `Documents/Inbox` scan) and the share extension's App Group inbox.
///
/// Import is a two-phase pipeline. `prepare` (read, hash, parse) and `commit` (write the entry
/// folder) both run off the main actor; the coordinator itself only sequences the work, reloads
/// the `Catalog` on the main actor and drives the UI state. When a duplicate SHA-256 is found
/// the queue stalls on an alert so the user can choose; active duplicates from non-interactive
/// sources (opened files, inbox files) are skipped silently instead.
///
/// The queue is drained by a single `Task` (`processingTask`): each pass prepares one item,
/// commits it and **awaits** `catalog.reload()` before pulling the next, so a later item's
/// duplicate check always sees every earlier commit. Two guards sit on top of that for the
/// "same file arrives twice" race (B16): `trackedPaths` (a file path is queued, in flight or
/// stalled at most once) and `inFlightHashes` (a hash being committed is never started again).
///
/// `ImportCoordinator` is `@Observable` so `HomeView` can react to its state.
@MainActor @Observable
final class ImportCoordinator {
    // MARK: - Alert content

    /// Where the existing copy of a duplicate lives.
    enum DuplicateKind {
        /// The existing copy is in the catalogue.
        case active
        /// The existing copy is in the Trash.
        case trashed
    }

    struct DuplicateAlert {
        let kind: DuplicateKind
        let result: ImportResult
        let existingEntry: CatalogEntry
        let context: ItemContext
    }

    // MARK: - Queue items

    /// A file the app already owns a copy of (an inbox file). Deleted after a successful import,
    /// a skipped duplicate or a permanent failure; kept after a transient failure so the next
    /// drain retries it.
    struct OwnedFile {
        let url: URL
        /// The name used as the stored filename / title fallback (e.g. with the share
        /// extension's `<UUID>-` prefix already stripped). Defaults to the file's own name.
        let filename: String
        /// A staging folder removed together with the file (dropped files live in their own
        /// `tmp/DroppedFiles/<UUID>/` folder). `nil` for inbox files.
        let cleanupFolder: URL?

        init(url: URL, filename: String? = nil, cleanupFolder: URL? = nil) {
            self.url = url
            self.filename = filename ?? url.lastPathComponent
            self.cleanupFolder = cleanupFolder
        }
    }

    enum Source {
        /// A security-scoped URL from the file picker. Never deleted.
        case picker(URL)
        /// An app-owned copy of a file (opened file or inbox file).
        case owned(OwnedFile)
        /// Test seam: bytes with a filename, so tests need no file URLs.
        case prepared(data: Data, filename: String)
        /// A fetched and prepared new online list (`result.subscription` set). Never prompts
        /// as a duplicate.
        case subscribed(ImportResult)
    }

    struct PendingImport {
        let source: Source
        /// `true` when a person is looking at the result (picker): failures raise the error
        /// alert and an active duplicate prompts. Opened and inbox files are non-interactive.
        let interactive: Bool
    }

    /// What the coordinator must clean up when an item is finished.
    struct ItemContext {
        let filename: String
        let interactive: Bool
        let ownedURL: URL?
        var cleanupFolder: URL?
        let pathKey: String?
        /// The URL a new online list follows, held in `pendingSubscriptionURLs` until done.
        var subscriptionURL: URL?
    }

    // MARK: - Published state

    /// Non-nil while the duplicate-import alert is visible.
    var pendingDuplicate: DuplicateAlert?

    /// Non-nil when an import error should be presented to the user.
    var importError: Error?

    /// `true` while the queue is actively being processed (between enqueue and the queue
    /// draining / stalling on a duplicate). Drives the progress indicator in `HomeView`.
    private(set) var isImporting = false

    /// The display filename of the item currently being imported, for the progress label.
    var currentFilename: String?

    /// Items in the current batch (queued + finished). Reset when a new batch starts.
    private(set) var totalCount = 0

    /// Items of the current batch that are done (imported, skipped, failed or resolved from a
    /// duplicate prompt).
    var completedCount = 0

    /// The 1-based position of the item being imported, for "Importing 2 of 5".
    var currentPosition: Int {
        min(completedCount + 1, max(totalCount, 1))
    }

    /// Where non-interactive failures are recorded for the user.
    var failureLog: ImportFailureLog?

    // MARK: - Private state

    private var queue: [PendingImport] = []
    /// The single in-flight drain Task, if any. `drainForTesting` awaits it.
    private var processingTask: Task<Void, Never>?
    /// The read-and-parse of the item in flight, so `cancel()` can abort it.
    private var currentPrepare: Task<ImportResult, Error>?
    /// Normalised paths of files that are queued, being imported, or stalled on a prompt. A
    /// path is accepted once, so the opened file and the inbox scan that later lists the same
    /// file cannot both import it.
    var trackedPaths: Set<String> = []
    /// URLs of new online lists that are queued or being committed (and reloaded), so a second
    /// subscribe of the same URL does not add another list (`isSubscribing(to:)`).
    var pendingSubscriptionURLs: Set<URL> = []
    /// Hashes whose commit (and the reload that follows) has not finished yet.
    var inFlightHashes: Set<String> = []
    /// Hashes committed this session that `catalog.entries` may not show yet (a newer reload can
    /// overtake the one awaited after the commit, so it returns without publishing). Kept until
    /// the catalogue contains them, so an identical later item is still seen as a duplicate (B16).
    var recentlyCommittedHashes: Set<String> = []
    /// While `true` nothing is drained: items queue up. Held from launch until the first storage
    /// resolution (iCloud vs local) finishes, so no import commits into or checks against the
    /// wrong root.
    var isHeld: Bool {
        holdCount > 0
    }

    /// Nested holds: launch, and every storage application (toggle, recovery, re-resolve), each
    /// hold once and release once; draining resumes only when all have released.
    private var holdCount = 0

    init(failureLog: ImportFailureLog? = nil) {
        self.failureLog = failureLog
    }

    // MARK: - Hold / release

    /// Stops draining until `release` is called; enqueued items wait in the queue.
    func hold() {
        holdCount += 1
    }

    /// Holds and then waits for the item currently being read, committed and reloaded to
    /// finish, so nothing is mid-commit when the storage root is about to change. Items still
    /// queued stay queued (an item stalled on a duplicate prompt counts as idle).
    func holdAndWaitUntilIdle() async {
        hold()
        await processingTask?.value
    }

    /// The active root changed: hashes remembered as "committed, not yet visible" referred to
    /// the previous root, so a manual re-import of the same file must not be dropped for them.
    func storageDidChange() {
        recentlyCommittedHashes.removeAll()
    }

    /// Resumes draining and starts on anything queued while held.
    func release(catalog: Catalog, cache: ResourceCache) {
        holdCount = max(0, holdCount - 1)
        guard !isHeld else { return }
        if !queue.isEmpty {
            startProcessingIfNeeded(catalog: catalog, cache: cache)
        }
    }

    // MARK: - Entry points

    /// Enqueues security-scoped URLs from the file picker (interactive).
    func enqueue(_ urls: [URL], catalog: Catalog, cache: ResourceCache) {
        let items = urls.compactMap { url -> PendingImport? in
            guard track(url) else { return nil }
            return PendingImport(source: .picker(url), interactive: true)
        }
        append(items, catalog: catalog, cache: cache)
    }

    /// Enqueues staged copies of dropped files: app-owned (deleted with their staging folder
    /// when finished, however that happens) but interactive, like the picker.
    func enqueueDropped(_ urls: [URL], catalog: Catalog, cache: ResourceCache) {
        let items = urls.compactMap { url -> PendingImport? in
            guard track(url) else { return nil }
            let file = OwnedFile(url: url, cleanupFolder: url.deletingLastPathComponent())
            return PendingImport(source: .owned(file), interactive: true)
        }
        append(items, catalog: catalog, cache: cache)
    }

    /// Enqueues app-owned copies (opened files, inbox files). Non-interactive. Files already
    /// queued, in flight or stalled are ignored.
    ///
    /// - Returns: The number of files actually enqueued.
    @discardableResult
    func enqueueOwned(
        _ files: [OwnedFile],
        catalog: Catalog,
        cache: ResourceCache
    ) -> Int {
        let items = files.compactMap { file -> PendingImport? in
            guard track(file.url) else { return nil }
            return PendingImport(source: .owned(file), interactive: false)
        }
        append(items, catalog: catalog, cache: cache)
        return items.count
    }

    /// Test-only entry point: enqueues already-prepared `(data, filename)` pairs, bypassing the
    /// file read so unit tests need no file URLs. Both share the same dedup / commit / reload /
    /// stall logic.
    func enqueuePrepared(
        _ items: [(Data, String)],
        interactive: Bool = true,
        catalog: Catalog,
        cache: ResourceCache
    ) {
        let pending = items.map {
            PendingImport(source: .prepared(data: $0.0, filename: $0.1), interactive: interactive)
        }
        append(pending, catalog: catalog, cache: cache)
    }

    func append(_ items: [PendingImport], catalog: Catalog, cache: ResourceCache) {
        guard !items.isEmpty else { return }
        // A new batch starts when nothing is queued, running or stalled: restart the counters.
        if !isImporting, queue.isEmpty, pendingDuplicate == nil {
            totalCount = 0
            completedCount = 0
        }
        totalCount += items.count
        queue.append(contentsOf: items)
        startProcessingIfNeeded(catalog: catalog, cache: cache)
    }

    // MARK: - Cancel

    /// Drops every item that has not started yet and deletes the app-owned copies among them,
    /// and aborts the item currently being read and parsed (nothing is committed for it). An
    /// item already past prepare (committing, or stalled on a duplicate prompt) completes.
    func cancel() {
        currentPrepare?.cancel()
        let dropped = queue
        queue.removeAll()
        totalCount -= dropped.count
        for item in dropped {
            switch item.source {
            case let .owned(file):
                try? FileManager.default.removeItem(at: file.cleanupFolder ?? file.url)
                untrack(file.url)
            case let .picker(url):
                untrack(url)
            case .prepared:
                break
            case let .subscribed(result):
                if let url = result.subscription?.url {
                    pendingSubscriptionURLs.remove(url)
                }
            }
        }
    }

    // MARK: - Testing

    /// Awaits the in-flight drain Task (if any) so tests can deterministically wait for the
    /// queue to settle or stall on a duplicate. No-op in production.
    func drainForTesting() async {
        await processingTask?.value
    }

    // MARK: - Driving loop

    private func startProcessingIfNeeded(catalog: Catalog, cache: ResourceCache) {
        guard !isHeld, processingTask == nil, pendingDuplicate == nil else { return }
        startProcessing(catalog: catalog, cache: cache, leading: nil)
    }

    /// Starts a single drain Task that optionally runs `leading` first (the resolution of a
    /// duplicate), then processes the queue until it empties or stalls on a duplicate.
    /// `isImporting` is held `true` for the lifetime of the drain.
    func startProcessing(
        catalog: Catalog,
        cache: ResourceCache,
        leading: (@MainActor () async -> Void)?
    ) {
        guard processingTask == nil else { return }
        isImporting = true
        processingTask = Task { [weak self] in
            await leading?()
            await self?.drainQueue(catalog: catalog, cache: cache)
            guard let self else { return }
            isImporting = false
            currentFilename = nil
            processingTask = nil
        }
    }

    /// Processes queued items one at a time until the queue empties or a duplicate stalls it.
    private func drainQueue(catalog: Catalog, cache: ResourceCache) async {
        while !isHeld, pendingDuplicate == nil, !queue.isEmpty {
            let item = queue.removeFirst()
            await importItem(item, catalog: catalog, cache: cache)
        }
    }

    // MARK: - Single-item import

    private func importItem(
        _ item: PendingImport,
        catalog: Catalog,
        cache: ResourceCache
    ) async {
        let context = makeContext(for: item)
        currentFilename = context.filename

        // The prepare runs in its own task so `cancel()` can abort just this item's read and
        // parse (the cancellation reaches the detached work through its cancellation handler).
        let source = item.source
        let filename = context.filename
        let prepareTask = Task { try await prepare(source, filename: filename) }
        currentPrepare = prepareTask
        defer { currentPrepare = nil }

        let result: ImportResult
        do {
            result = try await prepareTask.value
        } catch {
            reportPrepareFailure(error, context)
            return
        }
        await processPrepared(result, context, catalog: catalog, cache: cache)
    }

    private func prepare(_ source: Source, filename: String) async throws -> ImportResult {
        switch source {
        case let .picker(url):
            // The security-scoped bracket spans the awaited detached hop, so the URL stays
            // accessible while the off-main read runs.
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            return try await readAndPrepareFile(url, filename: filename)
        case let .owned(file):
            let accessed = file.url.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    file.url.stopAccessingSecurityScopedResource()
                }
            }
            return try await readAndPrepareFile(file.url, filename: filename)
        case let .prepared(data, name):
            return try await prepareBytes(data, filename: name)
        case let .subscribed(result):
            return result
        }
    }
}
