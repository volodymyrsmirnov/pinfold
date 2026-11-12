import Foundation
import Observation
import os

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
        fileprivate let context: ItemContext
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

        init(url: URL, filename: String? = nil) {
            self.url = url
            self.filename = filename ?? url.lastPathComponent
        }
    }

    private enum Source {
        /// A security-scoped URL from the file picker. Never deleted.
        case picker(URL)
        /// An app-owned copy of a file (opened file or inbox file).
        case owned(OwnedFile)
        /// Test seam: bytes with a filename, so tests need no file URLs.
        case prepared(data: Data, filename: String)
    }

    private struct PendingImport {
        let source: Source
        /// `true` when a person is looking at the result (picker): failures raise the error
        /// alert and an active duplicate prompts. Opened and inbox files are non-interactive.
        let interactive: Bool
    }

    /// What the coordinator must clean up when an item is finished.
    fileprivate struct ItemContext {
        let filename: String
        let interactive: Bool
        let ownedURL: URL?
        let pathKey: String?
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
    private(set) var currentFilename: String?

    /// Items in the current batch (queued + finished). Reset when a new batch starts.
    private(set) var totalCount = 0

    /// Items of the current batch that are done (imported, skipped, failed or resolved from a
    /// duplicate prompt).
    private(set) var completedCount = 0

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
    /// Normalised paths of files that are queued, being imported, or stalled on a prompt. A
    /// path is accepted once, so the opened file and the inbox scan that later lists the same
    /// file cannot both import it.
    private var trackedPaths: Set<String> = []
    /// Hashes whose commit (and the reload that follows) has not finished yet.
    private var inFlightHashes: Set<String> = []
    /// Hashes committed this session that `catalog.entries` may not show yet (a newer reload can
    /// overtake the one awaited after the commit, so it returns without publishing). Kept until
    /// the catalogue contains them, so an identical later item is still seen as a duplicate (B16).
    var recentlyCommittedHashes: Set<String> = []
    /// While `true` nothing is drained: items queue up. Held from launch until the first storage
    /// resolution (iCloud vs local) finishes, so no import commits into or checks against the
    /// wrong root.
    private(set) var isHeld = false

    init(failureLog: ImportFailureLog? = nil) {
        self.failureLog = failureLog
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Pinfold",
        category: "import"
    )

    // MARK: - Hold / release

    /// Stops draining until `release` is called; enqueued items wait in the queue.
    func hold() {
        isHeld = true
    }

    /// Resumes draining and starts on anything queued while held.
    func release(catalog: Catalog, cache: ResourceCache) {
        isHeld = false
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

    private func append(_ items: [PendingImport], catalog: Catalog, cache: ResourceCache) {
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

    /// Drops every item that has not started yet and deletes the app-owned copies among them.
    /// The item currently in flight finishes (aborting it mid-parse is a later task).
    func cancel() {
        let dropped = queue
        queue.removeAll()
        totalCount -= dropped.count
        for item in dropped {
            switch item.source {
            case let .owned(file):
                try? FileManager.default.removeItem(at: file.url)
                untrack(file.url)
            case let .picker(url):
                untrack(url)
            case .prepared:
                break
            }
        }
    }

    // MARK: - Duplicate resolution

    /// "Import Anyway" (active duplicate) / "Import as New" (trashed duplicate): commits the
    /// copy and **awaits** `catalog.reload()` before resuming the queue, so the next item's
    /// duplicate check runs against the post-commit catalogue, never a stale snapshot.
    func importAnyway(catalog: Catalog, cache: ResourceCache) {
        guard let dup = pendingDuplicate else { return }
        pendingDuplicate = nil
        startProcessing(catalog: catalog, cache: cache) { [weak self] in
            await self?.commitAndFinish(dup.result, dup.context, catalog: catalog, cache: cache)
        }
    }

    /// "Restore from Trash": brings the trashed copy back instead of importing a second one.
    func restoreTrashedDuplicate(catalog: Catalog, cache: ResourceCache) {
        guard let dup = pendingDuplicate, dup.kind == .trashed else { return }
        pendingDuplicate = nil
        startProcessing(catalog: catalog, cache: cache) { [weak self] in
            // Keep the inbox copy when the restore failed (read-only entry, write error): the
            // user's file must not vanish without being imported or restored.
            let restored = await catalog.restore(dup.existingEntry)
            self?.finish(dup.context, deleteOwned: restored)
        }
    }

    /// "Skip" on the duplicate alert, or the alert dismissed by any other means. Idempotent: if
    /// the alert was already resolved this is a no-op so the queue is never advanced twice.
    func skipDuplicate(catalog: Catalog, cache: ResourceCache) {
        guard let dup = pendingDuplicate else { return }
        pendingDuplicate = nil
        finish(dup.context, deleteOwned: true)
        startProcessing(catalog: catalog, cache: cache, leading: nil)
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
    private func startProcessing(
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
        while pendingDuplicate == nil, !queue.isEmpty {
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

        let result: ImportResult
        do {
            result = try await prepare(item.source, filename: context.filename)
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
        }
    }

    /// Hands a prepared result to the duplicate check, then commits or stalls.
    private func processPrepared(
        _ result: ImportResult,
        _ context: ItemContext,
        catalog: Catalog,
        cache: ResourceCache
    ) async {
        if inFlightHashes.contains(result.contentSHA256) {
            // The same bytes are already being committed: never start a second commit.
            finish(context, deleteOwned: true)
            return
        }
        recentlyCommittedHashes.subtract(catalog.entries.map(\.contentSHA256))
        guard let existing = duplicate(of: result, in: catalog) else {
            if recentlyCommittedHashes.contains(result.contentSHA256) {
                // Committed a moment ago but not published to the catalogue yet.
                finish(context, deleteOwned: true)
                return
            }
            await commitAndFinish(result, context, catalog: catalog, cache: cache)
            return
        }
        if existing.isTrashed || context.interactive {
            // Stall the queue on the prompt; the drain loop exits and a fresh drain starts once
            // the user resolves it. A trashed duplicate always prompts (B9), from every source.
            currentFilename = nil
            pendingDuplicate = DuplicateAlert(
                kind: existing.isTrashed ? .trashed : .active,
                result: result,
                existingEntry: existing,
                context: context
            )
        } else {
            // Non-interactive active duplicate: skip silently and drop the copy.
            finish(context, deleteOwned: true)
        }
    }

    /// The catalogue entry with the same bytes, preferring an active one over a trashed one.
    private func duplicate(of result: ImportResult, in catalog: Catalog) -> CatalogEntry? {
        let matches = catalog.entries.filter { $0.contentSHA256 == result.contentSHA256 }
        return matches.first { !$0.isTrashed } ?? matches.first
    }

    /// Commits `result` off-main, awaits the catalog reload so the next item's duplicate check
    /// sees this commit, then finishes the item. A commit failure is reported (see
    /// `reportCommitFailure`) and leaves a non-interactive copy in place for a retry.
    private func commitAndFinish(
        _ result: ImportResult,
        _ context: ItemContext,
        catalog: Catalog,
        cache: ResourceCache
    ) async {
        inFlightHashes.insert(result.contentSHA256)
        defer { inFlightHashes.remove(result.contentSHA256) }
        do {
            // Resolved now, not captured at enqueue time: the active root can change (iCloud
            // switch at launch) while an item waits in the queue.
            _ = try await ImportService.commitOffMain(result, storage: catalog.storage, cache: cache)
            recentlyCommittedHashes.insert(result.contentSHA256)
            await catalog.reload()
            // A newer reload may have overtaken ours without publishing; retry a few times so
            // the entry is visible, then forget the hash. If it still is not, it stays in
            // `recentlyCommittedHashes` and duplicate checks keep honouring it.
            var retries = 0
            while catalog.entry(withSHA256: result.contentSHA256) == nil, retries < 3 {
                retries += 1
                await catalog.reload()
            }
            if catalog.entry(withSHA256: result.contentSHA256) != nil {
                recentlyCommittedHashes.remove(result.contentSHA256)
            }
            finish(context, deleteOwned: true)
        } catch {
            reportCommitFailure(error, context)
        }
    }

    // MARK: - Finishing and failures

    private func makeContext(for item: PendingImport) -> ItemContext {
        switch item.source {
        case let .picker(url):
            ItemContext(filename: url.lastPathComponent, interactive: true, ownedURL: nil, pathKey: Self.key(url))
        case let .owned(file):
            ItemContext(filename: file.filename, interactive: false, ownedURL: file.url, pathKey: Self.key(file.url))
        case let .prepared(_, name):
            ItemContext(filename: name, interactive: item.interactive, ownedURL: nil, pathKey: nil)
        }
    }

    /// Marks an item done: optionally deletes its app-owned copy, releases its path, and
    /// advances the progress count.
    private func finish(_ context: ItemContext, deleteOwned: Bool) {
        if deleteOwned, let url = context.ownedURL {
            try? FileManager.default.removeItem(at: url)
        }
        if let key = context.pathKey {
            trackedPaths.remove(key)
        }
        completedCount += 1
    }

    /// A read or parse failure. A parse failure is permanent (the bytes are not valid
    /// KML/KMZ), so the owned copy is deleted; a read error is potentially transient, so the
    /// copy is kept for the next drain. A vanished file is simply gone.
    private func reportPrepareFailure(_ error: Error, _ context: ItemContext) {
        if context.interactive {
            importError = error
            finish(context, deleteOwned: false)
            return
        }
        let permanent = Self.isParseFailure(error)
        let vanished = (error as? CocoaError)?.code == .fileReadNoSuchFile
        if !vanished {
            Self.logger.error(
                """
                \(permanent ? "Parse" : "Read") failure importing '\(context.filename, privacy: .public)': \
                \(error.localizedDescription, privacy: .public)
                """
            )
            failureLog?.record(
                filename: context.filename,
                reason: permanent ? ImportFormats.invalidFileReason : Self.retryReason
            )
        }
        finish(context, deleteOwned: permanent || vanished)
    }

    private static func isParseFailure(_ error: Error) -> Bool {
        guard let importError = error as? ImportError else { return false }
        if case .parseFailure = importError {
            return true
        }
        return false
    }

    /// A commit (I/O) failure: potentially transient, so a non-interactive copy is KEPT for a
    /// later drain and the failure is recorded with a friendly reason; an interactive import
    /// raises the error alert.
    private func reportCommitFailure(_ error: Error, _ context: ItemContext) {
        if context.interactive {
            importError = error
        } else {
            Self.logger.error(
                """
                Transient failure importing '\(context.filename, privacy: .public)': \
                \(error.localizedDescription, privacy: .public)
                """
            )
            failureLog?.record(filename: context.filename, reason: Self.retryReason)
        }
        finish(context, deleteOwned: false)
    }

    private static let retryReason = String(
        localized: "Couldn't save the file. It will be retried automatically.",
        comment: "Import failure reason: a transient I/O error; the import will be retried."
    )

    // MARK: - Path tracking

    /// Normalised key for a file URL (symlinks such as `/var` vs `/private/var` resolved).
    private static func key(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Registers `url`; `false` when it is already queued, in flight or stalled.
    private func track(_ url: URL) -> Bool {
        trackedPaths.insert(Self.key(url)).inserted
    }

    private func untrack(_ url: URL) {
        trackedPaths.remove(Self.key(url))
    }
}
