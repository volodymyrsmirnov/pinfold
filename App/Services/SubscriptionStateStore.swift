import Foundation
import PinfoldCore

/// Per-device refresh bookkeeping for a subscribed list. Lives in the local `resources/`
/// folder, never in the synced sidecar, so devices don't fight over fetch timestamps.
struct SubscriptionState: Codable, Equatable, Sendable {
    var lastAttemptAt: Date?
    var lastSuccessAt: Date?
    var lastError: String?
    var etag: String?
    var lastModified: String?
    var serverMinRefreshPeriod: TimeInterval?
    /// `NetworkLinkControl` `<expires>`.
    var serverExpires: Date?
    /// `Cache-Control: max-age` or `Expires` header, resolved to a date.
    var httpExpires: Date?
    /// SHA-256 of the original the validators (`etag`, `lastModified`) and the server hints
    /// describe. Validators are sent only while it equals the original actually on disk, so a
    /// crash or an iCloud conflict that left other bytes there is repaired by a full fetch.
    var contentSHA256: String?
}

extension SubscriptionState {
    /// This state with every hint safe to store and schedule with: `serverMinRefreshPeriod`
    /// sanitised like a file's hints (`KMLRefreshHint`), dates that are not finite dropped.
    var sanitised: SubscriptionState {
        var safe = self
        safe.serverMinRefreshPeriod = KMLRefreshHint.sanitised(serverMinRefreshPeriod)
        safe.lastAttemptAt = Self.finite(lastAttemptAt)
        safe.lastSuccessAt = Self.finite(lastSuccessAt)
        safe.serverExpires = Self.finite(serverExpires)
        safe.httpExpires = Self.finite(httpExpires)
        return safe
    }

    private static func finite(_ date: Date?) -> Date? {
        date.flatMap { $0.timeIntervalSinceReferenceDate.isFinite ? $0 : nil }
    }
}

enum SubscriptionStateStore {
    static let filename = "subscription-state.json"

    /// A missing or corrupt file yields a default (never-attempted) state.
    static func read(in resourcesDir: URL) -> SubscriptionState {
        let url = resourcesDir.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return SubscriptionState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(SubscriptionState.self, from: data)) ?? SubscriptionState()
    }

    /// Writes atomically, creating the directory if needed. Best effort: state is derivable.
    /// Non-finite hints are dropped first (`sanitised`): JSON cannot hold them, and the whole
    /// write would fail.
    static func write(_ state: SubscriptionState, in resourcesDir: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(state.sanitised) else { return }
        try? FileManager.default.createDirectory(at: resourcesDir, withIntermediateDirectories: true)
        try? data.write(to: resourcesDir.appendingPathComponent(filename), options: .atomic)
    }

    static func remove(in resourcesDir: URL) {
        try? FileManager.default.removeItem(at: resourcesDir.appendingPathComponent(filename))
    }
}
