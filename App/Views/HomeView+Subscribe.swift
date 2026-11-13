import SwiftUI

extension HomeView {
    /// Opens the "Subscribe to URL" alert with an empty field.
    func beginSubscribe() {
        guard !isSubscribing else { return }
        subscribeText = ""
        isSubscribeAlertPresented = true
    }

    /// Normalises the typed address and subscribes. Invalid input shows the error alert; a list
    /// that already follows the URL (or was converted) is selected. A new list goes on the
    /// import queue, which commits it.
    func runSubscribe() {
        guard !isSubscribing else { return }
        guard let url = SubscriptionURL.normalise(subscribeText) else {
            subscribeError = String(localized: "Enter a web address that starts with https://")
            return
        }
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
            } catch {
                subscribeError = error.localizedDescription
            }
        }
    }
}

/// The "Subscribe to URL" alert and its error alert. A `ViewModifier` so `HomeView.body` stays
/// small for the type-checker.
struct SubscribeAlertsModifier: ViewModifier {
    @Binding var isPresented: Bool
    @Binding var text: String
    @Binding var error: String?
    let isSubscribing: Bool
    let subscribe: () -> Void

    func body(content: Content) -> some View {
        content
            .alert("Subscribe to URL", isPresented: $isPresented) {
                TextField("https://example.com/map.kml", text: $text)
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
                isPresented: Binding(get: { error != nil }, set: {
                    if !$0 {
                        error = nil
                    }
                }),
                presenting: error
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
