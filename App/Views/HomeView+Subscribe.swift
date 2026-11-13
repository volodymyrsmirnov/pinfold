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
