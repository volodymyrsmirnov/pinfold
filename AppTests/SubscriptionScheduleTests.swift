import Foundation
@testable import Pinfold
import PinfoldCore
import Testing

struct SubscriptionScheduleTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func sub(mode: KMLRefreshMode? = nil, interval: TimeInterval? = nil) -> Subscription {
        Subscription(
            url: URL(string: "https://example.com/a.kml")!, origin: .url,
            subscribedAt: t0, refreshMode: mode, refreshInterval: interval
        )
    }

    private func entry(
        _ subscription: Subscription?, trashed: Bool = false, state: CatalogEntry.SidecarState = .ok
    ) -> CatalogEntry {
        CatalogEntry(
            id: UUID(), displayName: "T", sourceFilename: "t.kml", importDate: t0, pointCount: 1,
            contentSHA256: "x", storageFolderName: "f", trashedAt: trashed ? t0 : nil,
            subscription: subscription, sidecarState: state
        )
    }

    private func attempted(_ state: SubscriptionState = SubscriptionState()) -> SubscriptionState {
        var s = state
        s.lastAttemptAt = t0
        return s
    }

    private func due(_ s: Subscription, _ state: SubscriptionState) -> Date {
        SubscriptionSchedule.nextDue(for: s, state: state, now: t0)
    }

    @Test func defaultInterval() {
        #expect(due(sub(mode: .onInterval, interval: 600), attempted()) == t0.addingTimeInterval(600))
        #expect(due(sub(), attempted()) == t0.addingTimeInterval(3600))
        #expect(due(sub(mode: .onChange), attempted()) == t0.addingTimeInterval(3600))
    }

    @Test func floorApplies() {
        #expect(due(sub(mode: .onInterval, interval: 30), attempted()) == t0.addingTimeInterval(300))
        let state = attempted(SubscriptionState(serverMinRefreshPeriod: 900))
        #expect(due(sub(mode: .onInterval, interval: 600), state) == t0.addingTimeInterval(900))
    }

    @Test func onExpire() {
        let s = sub(mode: .onExpire)
        #expect(due(s, attempted(SubscriptionState(serverExpires: t0.addingTimeInterval(7200))))
            == t0.addingTimeInterval(7200))
        #expect(due(s, attempted(SubscriptionState(httpExpires: t0.addingTimeInterval(1800))))
            == t0.addingTimeInterval(1800))
        #expect(due(s, attempted()) == t0.addingTimeInterval(3600))
        #expect(due(s, attempted(SubscriptionState(serverExpires: t0.addingTimeInterval(60))))
            == t0.addingTimeInterval(300))
    }

    @Test func failure_retriesAtFloor() {
        let state = attempted(SubscriptionState(lastError: "boom"))
        #expect(due(sub(mode: .onInterval, interval: 7200), state) == t0.addingTimeInterval(300))
    }

    @Test func neverAttempted_dueNow() {
        let e = entry(sub())
        #expect(due(sub(), SubscriptionState()) == t0)
        #expect(SubscriptionSchedule.isDue(e, state: SubscriptionState(), now: t0))
    }

    @Test func nonFiniteOrNegativeHints_areIgnored() {
        #expect(due(sub(mode: .onInterval, interval: .nan), attempted()) == t0.addingTimeInterval(3600))
        #expect(due(sub(mode: .onInterval, interval: .infinity), attempted()) == t0.addingTimeInterval(3600))
        let state = attempted(SubscriptionState(serverMinRefreshPeriod: -5))
        #expect(due(sub(mode: .onInterval, interval: 30), state) == t0.addingTimeInterval(300))
    }

    @Test func isDue_respectsTime() {
        let e = entry(sub(mode: .onInterval, interval: 600))
        let state = attempted()
        #expect(!SubscriptionSchedule.isDue(e, state: state, now: t0.addingTimeInterval(599)))
        #expect(SubscriptionSchedule.isDue(e, state: state, now: t0.addingTimeInterval(600)))
    }

    @Test func neverDue_forTrashedReadOnlyOrUnsubscribed() {
        let later = t0.addingTimeInterval(100_000)
        #expect(!SubscriptionSchedule.isDue(entry(sub(), trashed: true), state: attempted(), now: later))
        #expect(!SubscriptionSchedule.isDue(entry(sub(), state: .notDownloaded), state: attempted(), now: later))
        #expect(!SubscriptionSchedule.isDue(entry(nil), state: attempted(), now: later))
    }

    // MARK: - Absurd hints (F1)

    @Test func hugeHints_areCappedAtThirtyDays() {
        let cap = KMLRefreshHint.maxSeconds
        #expect(due(sub(mode: .onInterval, interval: 1e30), attempted()) == t0.addingTimeInterval(cap))
        var slow = attempted()
        slow.serverMinRefreshPeriod = 1e30
        #expect(due(sub(), slow) == t0.addingTimeInterval(cap))
        var failed = slow
        failed.lastError = "boom"
        #expect(due(sub(), failed) == t0.addingTimeInterval(cap))
        var farExpiry = attempted()
        farExpiry.serverExpires = t0.addingTimeInterval(1e15)
        #expect(due(sub(mode: .onExpire), farExpiry) == t0.addingTimeInterval(cap))
    }

    @Test func timerDelay_isClampedToADay() {
        #expect(SubscriptionRefresher.timerDelay(until: t0.addingTimeInterval(1e21), now: t0) == 24 * 3600)
        #expect(SubscriptionRefresher.timerDelay(until: t0.addingTimeInterval(600), now: t0) == 600)
        #expect(SubscriptionRefresher.timerDelay(until: t0.addingTimeInterval(-60), now: t0) == 0)
    }
}
