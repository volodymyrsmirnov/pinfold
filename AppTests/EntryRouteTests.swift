import Foundation
@testable import Pinfold
import Testing

/// Tests for `EntryRoute` — the Codable navigation-route values persisted across launches —
/// and `RestoreBundle` plumbing helpers. Decoding is deliberately forgiving: anything that
/// isn't a valid, current-version payload yields an empty route list (the file then opens
/// at its placemark list, per the session-restoration spec's failure table).
struct EntryRouteTests {
    @Test func routes_roundTripThroughResumeData() {
        let routes: [EntryRoute] = [
            .placemark(stableKey: "h:Cafe|1.5|2.5"),
            .map(focusKey: "h:Cafe|1.5|2.5"),
            .map(focusKey: nil),
        ]
        let data = EntryRoute.encodeForResume(routes)
        #expect(data != nil)
        #expect(EntryRoute.decodeForResume(data) == routes)
    }

    @Test func decode_nilData_isEmpty() {
        #expect(EntryRoute.decodeForResume(nil).isEmpty)
    }

    @Test func decode_corruptData_isEmpty() {
        #expect(EntryRoute.decodeForResume(Data("not json".utf8)).isEmpty)
    }

    @Test func decode_foreignVersion_isEmpty() {
        let foreign = Data(#"{"version":99,"routes":[]}"#.utf8)
        #expect(EntryRoute.decodeForResume(foreign).isEmpty)
    }

    @Test func validate_keepsValidPrefix_truncatesAtFirstStaleKey() {
        let routes: [EntryRoute] = [
            .placemark(stableKey: "good"),
            .placemark(stableKey: "stale"),
            .placemark(stableKey: "good"),
        ]
        let valid = EntryRoute.validatedForRestore(routes) { $0 == "good" }
        #expect(valid == [.placemark(stableKey: "good")])
    }

    @Test func validate_dropsMapFocusKey() {
        // A restored map route must NOT re-focus its pin: the saved per-file camera
        // encodes where the user actually was and wins over a focus zoom (spec).
        let valid = EntryRoute.validatedForRestore([.map(focusKey: "any")]) { _ in true }
        #expect(valid == [.map(focusKey: nil)])
    }

    @Test func validate_emptyIn_emptyOut() {
        #expect(EntryRoute.validatedForRestore([]) { _ in true }.isEmpty)
    }
}
