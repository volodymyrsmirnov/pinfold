import Foundation
import PinfoldCore

/// Pure due-date logic for subscribed lists. No clocks inside: `now` is always passed in.
enum SubscriptionSchedule {
    static let defaultInterval: TimeInterval = 3600
    static let floor: TimeInterval = 300

    /// A hint is usable only when it is finite and positive; anything else is treated as absent.
    private static func usable(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func effectiveFloor(_ state: SubscriptionState) -> TimeInterval {
        max(floor, usable(state.serverMinRefreshPeriod) ?? 0)
    }

    /// The steady-state gap between a successful attempt and the next one.
    static func interval(for sub: Subscription, state: SubscriptionState, now: Date) -> TimeInterval {
        let minimum = effectiveFloor(state)
        switch sub.refreshMode {
        case .onInterval:
            return max(minimum, usable(sub.refreshInterval) ?? defaultInterval)
        case .onExpire:
            let expires = state.serverExpires ?? state.httpExpires
            guard let expires else { return max(minimum, defaultInterval) }
            let base = state.lastAttemptAt ?? now
            return max(minimum, expires.timeIntervalSince(base))
        case .onChange, nil:
            return max(minimum, defaultInterval)
        }
    }

    static func nextDue(for sub: Subscription, state: SubscriptionState, now: Date) -> Date {
        guard let attempt = state.lastAttemptAt else { return now }
        if state.lastError != nil {
            return attempt.addingTimeInterval(effectiveFloor(state))
        }
        return attempt.addingTimeInterval(interval(for: sub, state: state, now: now))
    }

    static func isDue(_ entry: CatalogEntry, state: SubscriptionState, now: Date) -> Bool {
        guard let sub = entry.subscription, !entry.isTrashed, !entry.isReadOnly else { return false }
        return nextDue(for: sub, state: state, now: now) <= now
    }
}
