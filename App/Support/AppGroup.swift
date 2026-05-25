import Foundation

/// Shared App Group identifier used for the share-extension handoff inbox.
/// Must match the `com.apple.security.application-groups` entry in both the app and
/// share-extension entitlements, and the literal in `ShareViewController`.
enum AppGroup {
    static let identifier = "group.tech.inkhorn.pinfold"

    /// Root of the shared container, or nil if the App Group is unavailable.
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// Inbox directory where the share extension drops files awaiting import.
    static var inboxURL: URL? {
        containerURL?.appendingPathComponent("Inbox", isDirectory: true)
    }
}
