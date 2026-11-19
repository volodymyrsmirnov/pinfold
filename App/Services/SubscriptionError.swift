import Foundation

/// Why refreshing an online list failed. The description is what the list shows and records.
enum SubscriptionError: Error, LocalizedError, Equatable {
    case http(Int), tooLarge, notSupported, linkOnly, network(String), writeFailed(String), readOnly

    var errorDescription: String? {
        switch self {
        case let .http(status):
            String(localized: "The server returned an error (HTTP \(status)).")
        case .tooLarge:
            String(localized: "The file is larger than 50 MB.")
        case .notSupported:
            String(localized: "The server didn't return a KML, KMZ, GPX or GeoJSON file.")
        case .linkOnly:
            String(localized: "The server returned a file that only links to other files.")
        case let .network(reason):
            reason
        case let .writeFailed(reason):
            String(localized: "The update couldn't be saved: \(reason)")
        case .readOnly:
            String(localized: "This list can't be changed on this device right now.")
        }
    }

    /// Maps a fetch failure (`DownloadError`, cancellation or anything else) to a refresh error.
    init(fetchError error: Error) {
        switch error {
        case let DownloadError.httpStatus(status): self = .http(status)
        case DownloadError.tooLarge: self = .tooLarge
        case DownloadError.redirectedToOtherHost:
            self = .network(String(localized: "The server redirected to a different host."))
        case let DownloadError.transport(underlying): self = .network(underlying.localizedDescription)
        case is CancellationError: self = .network(String(localized: "The check was cancelled."))
        default: self = .network(error.localizedDescription)
        }
    }
}
