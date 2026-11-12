import Foundation

extension ResourceCache {
    /// `true` for an `http(s)` href, scheme compared case-insensitively (`HTTP://` too). The
    /// href itself is never rewritten: it is the manifest key `DescriptionView` looks up.
    nonisolated static func isRemoteHref(_ href: String) -> Bool {
        let lower = href.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
    }

    /// `true` for errors that say the *device* has no usable connection right now. Deliberately
    /// excludes `.cannotFindHost` / `.timedOut` / `.cannotConnectToHost`, which a dead or
    /// blocked host also produces and which must still back off.
    static func isConnectivityFailure(_ error: Error) -> Bool {
        // The live downloader wraps transport failures; look through that wrapper.
        if case let DownloadError.transport(underlying) = error {
            return isConnectivityFailure(underlying)
        }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
             .internationalRoamingOff, .callIsActive:
            return true
        default:
            return false
        }
    }
}
