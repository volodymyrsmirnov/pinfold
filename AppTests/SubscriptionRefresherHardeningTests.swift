import Foundation
@testable import Pinfold
import PinfoldCore
import Testing

/// `SubscriptionRefresher` hardening from the final review: absurd hints, validators tied to the
/// bytes on disk, eligibility re-checks after a fetch slot, the bounded pipeline, multi-window
/// state re-reads and quiet failures. Shares the fixtures of `SubscriptionRefresherTests`.
extension SubscriptionRefresherTests {
    // MARK: - Absurd hints (F1)

    @Test func timer_hugeIntervalHint_armsWithoutCrashing() async throws {
        let env = makeEnvironment()
        var prepared = try ImportService.prepare(data: kml(["Old"]), sourceFilename: "feed.kml")
        prepared.subscription = try Subscription(
            url: #require(URL(string: "https://example.test/slow.kml")), origin: .networkLink,
            subscribedAt: Date(timeIntervalSince1970: 1000), refreshMode: .onInterval, refreshInterval: 1e21
        )
        let entry = try ImportService.commit(prepared, storage: env.storage, cache: env.cache)
        SubscriptionStateStore.write(checkedAMinuteAgo, in: env.storage.resourcesDirectory(for: entry))
        await env.catalog.reload()
        let refresher = env.makeRefresher()

        await started(refresher)
        // Let the armed timer task start sleeping: an unclamped delay traps in `Duration.seconds`.
        for _ in 0 ..< 10 {
            await Task.yield()
        }

        #expect(env.stub.calls == 0)
        #expect(refresher.isTimerArmed)
        #expect(refresher.nextFireDate == Self.now.addingTimeInterval(KMLRefreshHint.maxSeconds - 60))
        refresher.sceneDidResignActive()
    }
}
