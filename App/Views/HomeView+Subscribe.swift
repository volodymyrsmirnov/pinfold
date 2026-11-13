import SwiftUI

/// The "Subscribe to URL" alert's state. What the person typed survives an error: an address
/// that isn't valid reopens the alert with it once the error is dismissed, and after a failed
/// subscribe the next alert starts with it. Only a subscribe that went through clears it.
struct SubscribePrompt: Equatable {
    var text = ""
    var isPresented = false
    var error: String?
    /// Reopen the alert when the error is dismissed (the address itself was refused).
    private var reopensAfterError = false

    /// Opens the alert, keeping the text of an attempt that did not go through.
    mutating func begin() {
        isPresented = true
    }

    /// The typed address as an `https` URL, or `nil` with the error set (and the alert to
    /// reopen with the same text once the person dismisses it).
    mutating func submit() -> URL? {
        guard let url = SubscriptionURL.normalise(text) else {
            error = String(localized: "Enter a web address that starts with https://")
            reopensAfterError = true
            return nil
        }
        return url
    }

    /// The subscribe failed: show why. The text stays for the next attempt.
    mutating func failed(_ message: String) {
        error = message
    }

    /// The subscribe went through: the next alert starts empty.
    mutating func succeeded() {
        text = ""
    }

    mutating func dismissError() {
        error = nil
        if reopensAfterError {
            reopensAfterError = false
            isPresented = true
        }
    }
}

extension HomeView {
    /// Opens the "Subscribe to URL" alert.
    func beginSubscribe() {
        guard !isSubscribing else { return }
        subscribePrompt.begin()
    }

    /// Normalises the typed address and subscribes. Invalid input shows the error alert, then
    /// the alert again with the text; a list that already follows the URL (or was converted)
    /// is selected. A new list goes on the import queue, which commits it.
    func runSubscribe() {
        guard !isSubscribing, let url = subscribePrompt.submit() else { return }
        isSubscribing = true
        let service = SubscriptionService(
            catalog: catalog, coordinator: importCoordinator, cache: resourceCache, refresher: refresher
        )
        Task {
            defer { isSubscribing = false }
            do {
                switch try await service.subscribe(to: url, origin: .url) {
                case let .existing(id), let .converted(id):
                    selection = id
                case .enqueued:
                    break
                }
                subscribePrompt.succeeded()
            } catch {
                subscribePrompt.failed(error.localizedDescription)
            }
        }
    }
}

/// The "Subscribe to URL" alert and its error alert. A `ViewModifier` so `HomeView.body` stays
/// small for the type-checker.
struct SubscribeAlertsModifier: ViewModifier {
    @Binding var prompt: SubscribePrompt
    let isSubscribing: Bool
    let subscribe: () -> Void

    func body(content: Content) -> some View {
        content
            .alert("Subscribe to URL", isPresented: $prompt.isPresented) {
                // A `String` title, not a `LocalizedStringKey`: a key is parsed as Markdown,
                // which turns the example URL into a link drawn in the tint colour, so the
                // placeholder looked like a pre-filled value.
                TextField(String(localized: "https://example.com/map.kml"), text: $prompt.text)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Cancel", role: .cancel) {}
                Button("Subscribe", action: subscribe)
                    .disabled(isSubscribing)
            } message: {
                Text(
                    "Pinfold will check this address for updates while the app is open. "
                        + "The host can see your device's IP address."
                )
            }
            .alert(
                "Couldn't Subscribe",
                isPresented: Binding(get: { prompt.error != nil }, set: {
                    if !$0 {
                        prompt.dismissError()
                    }
                }),
                presenting: prompt.error
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
    }
}

extension HomeView {
    /// The row's trailing status for an online list; `nil` for a normal list.
    func onlineStatus(for entry: CatalogEntry) -> FileRow.OnlineStatus? {
        guard entry.isOnline else { return nil }
        switch refresher.phase(for: entry) {
        case .idle: return .idle(lastSuccess: refresher.lastSuccess(for: entry))
        case .refreshing: return .refreshing
        case .failed: return .failed
        }
    }

    /// Row menu "Refresh Now". A plain `Task`, never inside a storage-queue operation.
    func runRefreshNow(_ entry: CatalogEntry) {
        Task { refreshError = await refresher.refreshNowMessage(entry) }
    }

    /// Confirmed "Stop Updating": the list stays as a normal one.
    func runStopUpdating(_ entry: CatalogEntry) {
        Task { refreshError = await refresher.stopUpdatingMessage(entry) }
    }
}

extension SubscriptionRefresher {
    /// Refreshes now and returns the failure text to show, or `nil` on success. Shared by the
    /// catalogue row menu and the list screen's ⋯ menu.
    func refreshNowMessage(_ entry: CatalogEntry) async -> String? {
        if case let .failure(error) = await refreshNow(entry) {
            return error.localizedDescription
        }
        return nil
    }

    /// Stops updating and returns the failure text to show, or `nil` on success.
    func stopUpdatingMessage(_ entry: CatalogEntry) async -> String? {
        do {
            try await stopUpdating(entry)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

/// The Stop Updating confirmation and the Refresh Now failure alert.
struct OnlineListDialogsModifier: ViewModifier {
    @Binding var stopTarget: CatalogEntry?
    @Binding var refreshError: String?
    let stop: (CatalogEntry) -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                stopTarget.map {
                    String(localized: "Stop updating \u{201C}\($0.displayName)\u{201D}? The current copy stays as a normal list.")
                } ?? "",
                isPresented: Binding(get: { stopTarget != nil }, set: {
                    if !$0 {
                        stopTarget = nil
                    }
                }),
                titleVisibility: .visible,
                presenting: stopTarget
            ) { entry in
                Button("Stop Updating", role: .destructive) { stop(entry) }
                Button("Cancel", role: .cancel) {}
            }
            .alert(
                "Couldn't Update",
                isPresented: Binding(get: { refreshError != nil }, set: {
                    if !$0 {
                        refreshError = nil
                    }
                }),
                presenting: refreshError
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
    }
}
