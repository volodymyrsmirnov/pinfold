import Foundation
@testable import Pinfold
import Testing

/// Tests for `ImportFailureLog` — the bounded, newest-first record of import failures that
/// `HomeView` surfaces to the user.
@Suite(.serialized) @MainActor struct ImportFailureLogTests {
    @Test func record_appendsAndCaps() {
        let log = ImportFailureLog()

        for index in 0 ..< 25 {
            log.record(filename: "file-\(index).kml", reason: "reason-\(index)")
        }

        #expect(log.failures.count == 20, "The log must cap at 20 entries")
        // Newest kept: the last recorded failure must be present.
        #expect(log.failures.contains { $0.filename == "file-24.kml" }, "Newest failure must be retained")
        // Oldest 5 dropped: files 0...4 must have been evicted.
        for index in 0 ..< 5 {
            #expect(
                !log.failures.contains { $0.filename == "file-\(index).kml" },
                "Oldest failure file-\(index).kml must have been evicted"
            )
        }
    }

    @Test func clear_empties() {
        let log = ImportFailureLog()
        log.record(filename: "a.kml", reason: "boom")
        log.record(filename: "b.kml", reason: "boom")
        #expect(!log.failures.isEmpty)

        log.clear()

        #expect(log.failures.isEmpty, "clear() must empty the log")
    }
}
