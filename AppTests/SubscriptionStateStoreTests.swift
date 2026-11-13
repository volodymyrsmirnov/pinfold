import Foundation
@testable import Pinfold
import PinfoldCore
import Testing

struct SubscriptionStateStoreTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("resources", isDirectory: true)
    }

    @Test func roundTrip() {
        let dir = tempDir()
        let state = SubscriptionState(
            lastAttemptAt: Date(timeIntervalSince1970: 1000),
            lastSuccessAt: Date(timeIntervalSince1970: 900),
            lastError: "boom",
            etag: "\"abc\"",
            lastModified: "Wed, 21 Oct 2026 07:28:00 GMT",
            serverMinRefreshPeriod: 900,
            serverExpires: Date(timeIntervalSince1970: 5000),
            httpExpires: Date(timeIntervalSince1970: 6000)
        )
        SubscriptionStateStore.write(state, in: dir)
        #expect(SubscriptionStateStore.read(in: dir) == state)
    }

    @Test func missingFile_returnsDefault() {
        #expect(SubscriptionStateStore.read(in: tempDir()) == SubscriptionState())
    }

    @Test func corruptFile_returnsDefault() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appendingPathComponent(SubscriptionStateStore.filename))
        #expect(SubscriptionStateStore.read(in: dir) == SubscriptionState())
    }

    @Test func remove_deletesFile() {
        let dir = tempDir()
        SubscriptionStateStore.write(SubscriptionState(etag: "x"), in: dir)
        let file = dir.appendingPathComponent(SubscriptionStateStore.filename)
        #expect(FileManager.default.fileExists(atPath: file.path))
        SubscriptionStateStore.remove(in: dir)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func nonFiniteHints_areDropped_andTheStatePersists() {
        let dir = tempDir()
        let state = SubscriptionState(
            lastAttemptAt: Date(timeIntervalSince1970: 1000), serverMinRefreshPeriod: .infinity,
            httpExpires: Date(timeIntervalSinceReferenceDate: .infinity)
        )
        SubscriptionStateStore.write(state, in: dir)
        let read = SubscriptionStateStore.read(in: dir)
        #expect(read.lastAttemptAt == Date(timeIntervalSince1970: 1000))
        #expect(read.serverMinRefreshPeriod == nil)
        #expect(read.httpExpires == nil)
    }

    @Test func subscription_withInfiniteHint_encodes() throws {
        let subscription = try Subscription(
            url: #require(URL(string: "https://example.test/a.kml")), origin: .networkLink,
            subscribedAt: Date(timeIntervalSince1970: 1000), refreshMode: .onInterval, refreshInterval: .infinity
        )
        let data = try JSONEncoder().encode(subscription)
        let decoded = try JSONDecoder().decode(Subscription.self, from: data)
        #expect(decoded.refreshInterval == nil)
        #expect(decoded.refreshMode == .onInterval)
    }
}
