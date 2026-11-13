import Foundation
import PinfoldCore

/// The fetch half of a refresh: the conditional GET and the classification of its response.
extension SubscriptionRefresher {
    /// Reads and hashes the original off the main actor.
    nonisolated static let liveOriginalHasher: OriginalHasher = { url in await sha256OfFileOffMain(url) }

    /// Fetches the subscription and classifies the response. Everything is checked against the
    /// original actually on disk, not only the sidecar: the stored validators are sent only when
    /// they describe those bytes (`SubscriptionState.contentSHA256`), and a `200` is unchanged
    /// only when its bytes equal them and the sidecar agrees. A crash between the sidecar update
    /// and the rename, or an iCloud conflict won by older bytes, is so repaired by the next
    /// refresh instead of hidden behind a `304` or a matching sidecar hash. An original that
    /// can't be read (an iCloud placeholder) is compared through the sidecar's hash instead, so
    /// unchanged bytes are not written again.
    ///
    /// - Returns: `nil` when the refresh should no longer run once the original is hashed (see
    ///   `isStillEligible`): nothing was requested.
    func fetch(_ subscription: Subscription, for entry: CatalogEntry, automatic: Bool) async -> FetchOutcome? {
        let live = liveEntry(entry.storageFolderName) ?? entry
        let state = state(for: live)
        let onDisk = await hashOriginal(catalog.storage.originalFile(for: live))
        // Hashing suspends: the scene may have left the foreground, or Stop Updating finished.
        guard isStillEligible(live.storageFolderName, subscription: subscription, automatic: automatic) else {
            return nil
        }
        let validated = onDisk != nil && state.contentSHA256 == onDisk
        let response: ConditionalResponse
        do {
            response = try await fetcher(
                subscription.url, validated ? state.etag : nil, validated ? state.lastModified : nil
            )
        } catch {
            return .failed(SubscriptionError(fetchError: error))
        }
        guard case let .data(data) = response.body else {
            return .unchanged(response, content: validated ? onDisk : nil, hints: nil)
        }
        let verified = (onDisk ?? live.contentSHA256) == live.contentSHA256 ? live.contentSHA256 : nil
        // The stored server hints come from other content (a synced device that never fetched
        // this file, or a state from before the content hash was kept): read them from the
        // bytes even when they are unchanged, so `minRefreshPeriod` is honoured.
        let readHints = state.contentSHA256 != verified
        switch await classifyOffMain(data, filename: live.sourceFilename, currentSHA: verified, readHints: readHints) {
        case let .same(hints): return .unchanged(response, content: verified, hints: hints)
        case let .changed(result): return .changed(result, response)
        case let .failed(error): return .failed(error)
        }
    }
}

// MARK: - Fetch outcome

enum FetchOutcome {
    /// `304`, or a `200` whose bytes match the original on disk. `content` is the SHA-256 the
    /// validators now describe (`nil`: leave the stored one); `hints` the server hints read
    /// from the unchanged bytes (`nil`: not read).
    case unchanged(ConditionalResponse, content: String?, hints: ServerHints?)
    case changed(ImportResult, ConditionalResponse)
    case failed(SubscriptionError)
}

/// A file's `<NetworkLinkControl>` hints; both `nil` when it has none.
struct ServerHints {
    let minRefreshPeriod: TimeInterval?
    let expires: Date?
}

private enum Classified: Sendable {
    case same(ServerHints?)
    case changed(ImportResult)
    case failed(SubscriptionError)
}

/// Hashes and validates fetched bytes off the main actor. Bytes equal to `currentSHA` are
/// `.same` and never fully prepared (with `readHints`, only parsed for their server hints).
/// A `nonisolated` free function so the detached closure is compiled outside any
/// actor-isolated caller (see FavoritesView.swift).
private nonisolated func classifyOffMain(
    _ data: Data, filename: String, currentSHA: String?, readHints: Bool
) async -> Classified {
    await Task.detached(priority: .utility) {
        if ImportService.sha256Hex(data) == currentSHA {
            guard readHints, let document = try? KMLReader.readDocument(data: data) else { return .same(nil) }
            let control = document.networkLinkControl
            return .same(ServerHints(minRefreshPeriod: control?.minRefreshPeriod, expires: control?.expires))
        }
        let result: ImportResult
        do {
            result = try ImportService.prepare(data: data, sourceFilename: filename)
        } catch {
            return .failed(.notSupported)
        }
        if result.placemarkCount == 0, result.networkLinkCount > 0 {
            return .failed(.linkOnly)
        }
        return .changed(result)
    }.value
}

/// The SHA-256 of the file at `url`, read off the main actor; `nil` when it can't be read
/// (missing, or an iCloud placeholder not downloaded yet).
private nonisolated func sha256OfFileOffMain(_ url: URL) async -> String? {
    await Task.detached(priority: .utility) {
        (try? Data(contentsOf: url)).map(ImportService.sha256Hex)
    }.value
}

// MARK: - Fetch slots

/// A main-actor counting semaphore bounding how many fetches run at once.
@MainActor final class FetchSlots {
    private var available: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        available = limit
    }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        if waiting.isEmpty {
            available += 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}
