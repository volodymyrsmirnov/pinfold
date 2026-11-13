import Foundation

/// One subscribe per URL at a time. The link card and the "Subscribe to URL" alert run separate
/// subscribes; both reserve the URL here (the refresher lives as long as the window, so every
/// flow in it sees the reservation) from their duplicate check through the hand-off to the
/// import queue, which then tracks the URL until the catalogue shows the new list
/// (`ImportCoordinator.isSubscribing(to:in:)`). A second subscribe of a reserved URL waits, then
/// finds the first one's list.
extension SubscriptionRefresher {
    /// Reserves `url`, waiting while another subscribe holds it. Pair with
    /// `releaseSubscription(_:)`.
    func reserveSubscription(_ url: URL) async {
        while subscribeReservations[url] != nil {
            await withCheckedContinuation { subscribeReservations[url, default: []].append($0) }
        }
        subscribeReservations[url] = []
    }

    /// Releases `url` and wakes the subscribes waiting for it (the first to run reserves it again).
    func releaseSubscription(_ url: URL) {
        let waiting = subscribeReservations.removeValue(forKey: url) ?? []
        waiting.forEach { $0.resume() }
    }
}
