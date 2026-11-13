import Foundation
import Observation

/// The in-session timer: one task sleeping until the earliest list is due (never sooner than
/// the floor), armed only while the scene is active and the device is online. Re-armed after
/// every refresh and Stop Updating, and whenever the catalogue or the network status changes
/// (subscribe, trash, restore and reloads all change `catalog.entries`).
extension SubscriptionRefresher {
    var isTimerArmed: Bool {
        timerTask != nil
    }

    /// Recomputes the timer from the current catalogue and refresh states.
    func rearm() {
        cancelTimer()
        guard isStarted, isSceneActive else { return }
        observationGeneration &+= 1
        let generation = observationGeneration
        let fireDate = withObservationTracking {
            timerFireDate()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observedChange(generation) }
        }
        lastSeenOnline = network?.isOnline ?? true
        guard let fireDate else { return }
        nextFireDate = fireDate
        timerTask = Task { [weak self, clock] in
            let delay = max(0, fireDate.timeIntervalSince(clock()))
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            timerTask = nil
            nextFireDate = nil
            await refreshDue()
        }
    }

    func cancelTimer() {
        timerTask?.cancel()
        timerTask = nil
        nextFireDate = nil
    }

    /// The earliest next-due date among online lists, but at least the floor from now. `nil`
    /// when offline or nothing is online. Reads `network.isOnline` and `catalog.entries` so the
    /// surrounding observation re-arms when either changes.
    private func timerFireDate() -> Date? {
        let online = network?.isOnline ?? true
        let entries = catalog.entries
        guard online else { return nil }
        let now = clock()
        let earliest = entries.compactMap { entry -> Date? in
            guard let subscription = entry.subscription, !entry.isTrashed, !entry.isReadOnly else { return nil }
            return SubscriptionSchedule.nextDue(for: subscription, state: state(for: entry), now: now)
        }.min()
        guard let earliest else { return nil }
        return max(earliest, now.addingTimeInterval(SubscriptionSchedule.floor))
    }

    /// The catalogue or the network changed: back online catches up on due lists (which
    /// re-arms); anything else re-arms. Ignores observations superseded by a later re-arm.
    private func observedChange(_ generation: Int) {
        guard generation == observationGeneration, isStarted, isSceneActive else { return }
        let online = network?.isOnline ?? true
        if online, !lastSeenOnline {
            lastSeenOnline = true
            activationTask = Task { await refreshDue() }
        } else {
            rearm()
        }
    }
}
