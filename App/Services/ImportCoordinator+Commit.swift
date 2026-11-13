/// Duplicate resolution and the commit step. A pure move out of `ImportCoordinator.swift`
/// (file length); members are internal only so the extension can reach the coordinator state.
extension ImportCoordinator {
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

    /// Hands a prepared result to the duplicate check, then commits or stalls.
    func processPrepared(
        _ result: ImportResult,
        _ context: ItemContext,
        catalog: Catalog,
        cache: ResourceCache
    ) async {
        if result.subscription != nil {
            // A new online list is its own list, whatever else has the same bytes: no duplicate
            // prompt and no hash dedup (`SubscriptionService` has already turned a matching
            // normal list into the online one instead of enqueueing).
            await commitAndFinish(result, context, catalog: catalog, cache: cache)
            return
        }
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
    func duplicate(of result: ImportResult, in catalog: Catalog) -> CatalogEntry? {
        let matches = catalog.entries.filter { $0.contentSHA256 == result.contentSHA256 }
        return matches.first { !$0.isTrashed } ?? matches.first
    }

    /// Whether `catalog` shows the commit of `result`: the committed entry itself for a new
    /// online list, else any entry with its bytes.
    private static func isShown(_ committed: CatalogEntry, for result: ImportResult, in catalog: Catalog) -> Bool {
        if result.subscription != nil {
            return catalog.entries.contains { $0.id == committed.id }
        }
        return catalog.entry(withSHA256: result.contentSHA256) != nil
    }

    /// Commits `result` off-main, awaits the catalog reload so the next item's duplicate check
    /// sees this commit, then finishes the item. A commit failure is reported (see
    /// `reportCommitFailure`) and leaves a non-interactive copy in place for a retry.
    func commitAndFinish(
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
            let committed = try await ImportService.commitOffMain(result, storage: catalog.storage, cache: cache)
            recentlyCommittedHashes.insert(result.contentSHA256)
            await catalog.reload()
            // A newer reload may have overtaken ours without publishing; retry a few times so
            // the entry is visible, then forget the hash. If it still is not, it stays in
            // `recentlyCommittedHashes` and duplicate checks keep honouring it. A new online
            // list is looked for by its own id: another list may have the same bytes.
            var retries = 0
            while !Self.isShown(committed, for: result, in: catalog), retries < 3 {
                retries += 1
                await catalog.reload()
            }
            if catalog.entry(withSHA256: result.contentSHA256) != nil {
                recentlyCommittedHashes.remove(result.contentSHA256)
            }
            if let url = result.subscription?.url, !Self.isShown(committed, for: result, in: catalog) {
                // Still being added as far as a subscribe is concerned (`isSubscribing(to:in:)`).
                committedSubscriptions[url] = committed
            }
            finish(context, deleteOwned: true)
        } catch {
            reportCommitFailure(error, context)
        }
    }
}
