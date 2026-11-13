import Foundation
import Observation

/// The in-session timer: one task sleeping until the earliest list is due (never sooner than
/// the floor), armed only while the scene is active and the device is online. Re-armed after
/// every refresh and Stop Updating, and whenever the catalogue or the network status changes
/// (subscribe, trash, restore and reloads all change `catalog.entries`).
///
/// State lives on `SubscriptionRefresher`: `timerTask`, `nextFireDate` (when the armed timer
/// fires), `lastDueCheck` (when due lists were last picked; the floor is measured from it, not
/// from each re-arm) and `observationGeneration` (identifies the latest catalogue/network
/// observation; older ones are ignored).
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
            let delay = SubscriptionRefresher.timerDelay(until: fireDate, now: clock())
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            timerTask = nil
            nextFireDate = nil
            await refreshDue()
        }
    }

    /// The longest the timer sleeps: one day. A timer that fires early just re-checks.
    nonisolated static let maxTimerDelay: TimeInterval = 24 * 3600

    /// Seconds to sleep until `fireDate`: never negative and never above `maxTimerDelay`, so
    /// no hint can overflow `Duration` (which traps).
    nonisolated static func timerDelay(until fireDate: Date, now: Date) -> TimeInterval {
        let delay = fireDate.timeIntervalSince(now)
        guard delay.isFinite else { return maxTimerDelay }
        return min(maxTimerDelay, max(0, delay))
    }

    func cancelTimer() {
        timerTask?.cancel()
        timerTask = nil
        nextFireDate = nil
    }

    /// Records that due lists are being picked now, and returns now.
    func markDueCheck() -> Date {
        let now = clock()
        lastDueCheck = now
        return now
    }

    /// The earliest the timer may fire: the floor after the last due check (or after now, when
    /// nothing was checked yet or the clock went back). Anchoring it to the last check rather
    /// than to the re-arm keeps frequent catalogue reloads from postponing a due list forever,
    /// while still stopping a list that is due but skipped (in flight) from re-firing at once.
    nonisolated static func earliestFire(lastDueCheck: Date?, now: Date) -> Date {
        let base = min(lastDueCheck ?? now, now)
        return base.addingTimeInterval(SubscriptionSchedule.floor)
    }

    /// The earliest next-due date among online lists, but not before `earliestFire`. `nil` when
    /// offline or nothing is online. Reads `network.isOnline` and `catalog.entries` so the
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
        return max(earliest, Self.earliestFire(lastDueCheck: lastDueCheck, now: now))
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
