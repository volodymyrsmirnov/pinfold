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
}
