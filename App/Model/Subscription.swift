import Foundation
import PinfoldCore

/// A list that follows a URL and refreshes itself. Stored in the entry's synced sidecar.
struct Subscription: Codable, Equatable, Sendable {
    enum Origin: String, Codable, Sendable {
        /// The user typed or pasted the URL.
        case url
        /// The URL came from a `<NetworkLink>` inside an imported file.
        case networkLink
    }

    /// The normalised https URL that is fetched.
    var url: URL
    var origin: Origin
    var subscribedAt: Date
    /// KML refresh hints, when the source file provided them.
    var refreshMode: KMLRefreshMode?
    var refreshInterval: TimeInterval?

    /// `refreshInterval` is sanitised (`KMLRefreshHint`): a non-finite value cannot be written
    /// to the sidecar, and a huge one would overflow the refresh timer.
    ///
    /// Decoding does not go through this initialiser: the synthesised `init(from:)` takes a
    /// sidecar's `refreshInterval` as it is (one written by another device or an older build).
    /// So the clamps where the interval is used, `SubscriptionSchedule`'s cap and the timer's
    /// `timerDelay(until:now:)`, are not redundant and must stay.
    init(
        url: URL, origin: Origin, subscribedAt: Date, refreshMode: KMLRefreshMode? = nil,
        refreshInterval: TimeInterval? = nil
    ) {
        self.url = url
        self.origin = origin
        self.subscribedAt = subscribedAt
        self.refreshMode = refreshMode
        self.refreshInterval = KMLRefreshHint.sanitised(refreshInterval)
    }
}
