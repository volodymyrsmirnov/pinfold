import UIKit
import UniformTypeIdentifiers

/// Light-work share extension: copies incoming .kml/.kmz files into the shared App Group
/// inbox, then launches the main app so the import is visible right away. The main app
/// drains the inbox and does the real import (parse, dedup, resource download) on launch
/// and whenever it returns to the foreground.
final class ShareViewController: UIViewController {
    /// MUST MATCH `AppGroup.identifier` in the main app (App/Support/AppGroup.swift).
    /// The extension is a separate module and cannot import the app target's Swift.
    private nonisolated static let appGroupID = "group.tech.inkhorn.pinfold"

    /// URL that foregrounds the main app. Must match a scheme in the app's
    /// `CFBundleURLTypes` (App/Info.plist). Opening it triggers the app's inbox drain.
    private static let launchURL = URL(string: "pinfold://import")!

    override func viewDidLoad() {
        super.viewDidLoad()
        handleSharedItems()
    }

    private func handleSharedItems() {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            return complete()
        }
        let group = DispatchGroup()
        for item in items {
            for provider in item.attachments ?? [] {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    defer { group.leave() }
                    guard let url = Self.fileURL(from: data) else { return }
                    Self.copyIntoInbox(url)
                }
            }
        }
        group.notify(queue: .main) { [weak self] in self?.openMainApp() }
    }

    /// Foregrounds the host app by walking the responder chain to a `UIApplication` and
    /// calling `open(_:)`. Share extensions have no `UIApplication.shared`, and
    /// `extensionContext.open(_:)` is not supported for share extensions, so the
    /// responder-chain walk is the standard way to launch the containing app.
    ///
    /// The extension request is completed only after `open(_:)` reports back, so the
    /// extension process isn't torn down before the launch request is delivered. If no
    /// `UIApplication` is found in the chain, the request completes immediately.
    private func openMainApp() {
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(Self.launchURL, options: [:]) { [weak self] _ in
                    self?.complete()
                }
                return
            }
            responder = current.next
        }
        complete()
    }

    /// Extracts a file URL from the loaded item value. Nonisolated and Sendable-safe.
    private nonisolated static func fileURL(from data: NSSecureCoding?) -> URL? {
        if let url = data as? URL { return url }
        if let data = data as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
        return nil
    }

    /// Copies a shared file into the App Group inbox. Nonisolated: touches only the
    /// file system and Sendable inputs, so it is safe to call from the loadItem closure.
    private nonisolated static func copyIntoInbox(_ url: URL) {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else { return }
        let inbox = container.appendingPathComponent("Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let dest = inbox.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        // Files vended by other apps (Files, Mail, …) may be security-scoped; without
        // claiming access first, the copy can silently fail.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try? FileManager.default.copyItem(at: url, to: dest)
    }

    private func complete() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}
