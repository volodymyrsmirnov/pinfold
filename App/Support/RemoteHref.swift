import Foundation

extension ResourceCache {
    /// `true` for an `http(s)` href, scheme compared case-insensitively (`HTTP://` too). The
    /// href itself is never rewritten: it is the manifest key `DescriptionView` looks up.
    nonisolated static func isRemoteHref(_ href: String) -> Bool {
        let lower = href.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
    }
}
