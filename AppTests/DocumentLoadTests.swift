import Foundation
@testable import Pinfold
import Testing

/// The pure parts of `KMLDetailView.loadDocument`: which errors are worth showing.
struct DocumentLoadTests {
    @Test func cancelledLoadSetsNoError() {
        #expect(DocumentLoad.reportableError(CancellationError()) == nil)
    }

    @Test func realFailureIsReported() {
        struct Boom: Error {}
        #expect(DocumentLoad.reportableError(Boom()) is Boom)
    }

    // MARK: - Reload pipeline (F6)

    @Test func contentAction_waitsForTheInitialLoad_thenReloadsOnlyOnADifferentHash() {
        #expect(DocumentLoad.contentAction(loadedSHA: nil, live: "a", documentLoaded: false) == .waitForInitialLoad)
        #expect(DocumentLoad.contentAction(loadedSHA: "a", live: "b", documentLoaded: false) == .waitForInitialLoad)
        #expect(DocumentLoad.contentAction(loadedSHA: "a", live: "a", documentLoaded: true) == .keep)
        #expect(DocumentLoad.contentAction(loadedSHA: "a", live: "b", documentLoaded: true) == .reload)
    }

    /// An in-place subscribe whose reload was overtaken left "Cannot Open File" on screen.
    @Test func contentAction_noDocumentWithALoadError_reloads() {
        #expect(
            DocumentLoad.contentAction(loadedSHA: nil, live: "b", documentLoaded: false, loadFailed: true) == .reload
        )
        #expect(
            DocumentLoad.contentAction(loadedSHA: nil, live: "b", documentLoaded: false, loadFailed: false)
                == .waitForInitialLoad
        )
        #expect(DocumentLoad.contentAction(loadedSHA: "a", live: "a", documentLoaded: true, loadFailed: true) == .keep)
    }

    @Test func contentKey_changesWithTheEntryOrItsContent() {
        let id = UUID()
        #expect(DocumentLoad.ContentKey(entryID: id, sha: "a") == DocumentLoad.ContentKey(entryID: id, sha: "a"))
        #expect(DocumentLoad.ContentKey(entryID: id, sha: "a") != DocumentLoad.ContentKey(entryID: id, sha: "b"))
        #expect(DocumentLoad.ContentKey(entryID: id, sha: "a") != DocumentLoad.ContentKey(entryID: UUID(), sha: "a"))
    }

    /// The UAT failure: a refresh keeps the old document on screen until the new one is parsed,
    /// so `documentLoaded` stays true; the outline must still rebuild for the new document even
    /// with no search active (before, only a search's corpus reset re-triggered it).
    @Test func outlineTrigger_changesWhenOnlyTheLoadedContentChanges() {
        func trigger(_ sha: String?) -> KMLDetailView.ImmediateOutlineTrigger {
            KMLDetailView.ImmediateOutlineTrigger(
                documentID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, documentLoaded: true,
                documentSHA: sha, collapsed: [], nearestFirst: false, corpusReady: false, notesRevision: 0,
                locationLat: nil, locationLon: nil
            )
        }
        #expect(trigger("a") != trigger("b"))
        #expect(trigger("a") == trigger("a"))
    }

    /// A→B→C: the first load's reconcile parses B, a content-keyed reload parses C, and B's
    /// parse finishes last. Only the newest load may publish, so C stays on screen.
    @Test func tickets_onlyTheNewestLoadPublishes_evenWhenAnOlderOneFinishesLast() {
        var tickets = DocumentLoad.Tickets()
        let loadA = tickets.issue()
        #expect(tickets.isCurrent(loadA))
        let loadB = tickets.issue() // the initial task reconciles with B
        let loadC = tickets.issue() // the keyed task reloads for C
        #expect(tickets.isCurrent(loadC)) // C finishes first: it publishes
        #expect(!tickets.isCurrent(loadB)) // B finishes last: dropped
        #expect(!tickets.isCurrent(loadA))
    }

    /// A content reload that fails while the old document is on screen keeps it there.
    @Test func failureToShow_keepsAShownDocument_andReportsOnlyWhenNothingIsShown() {
        struct Boom: Error {}
        #expect(DocumentLoad.failureToShow(Boom(), documentShown: true) == nil)
        #expect(DocumentLoad.failureToShow(Boom(), documentShown: false) is Boom)
        #expect(DocumentLoad.failureToShow(CancellationError(), documentShown: false) == nil)
    }

    /// A→B→A: A is shown and the first load's reconcile is parsing B when the live content
    /// reverts to A. The revert is `.keep`, so it starts no load and B's ticket stays the
    /// newest; B must still not replace A.
    @Test func mayPublish_staleParseAfterTheContentReverted_isDropped() {
        var tickets = DocumentLoad.Tickets()
        _ = tickets.issue() // the first load, which published A
        let parsingB = tickets.issue() // its reconcile, after the live content changed to B
        #expect(DocumentLoad.contentAction(loadedSHA: "A", live: "A", documentLoaded: true) == .keep)
        #expect(tickets.isCurrent(parsingB))

        #expect(!DocumentLoad.mayPublish(parsingB, of: tickets, loadedSHA: "B", liveSHA: "A", documentShown: true))
        #expect(DocumentLoad.mayPublish(parsingB, of: tickets, loadedSHA: "B", liveSHA: "B", documentShown: true))
        // With nothing on screen the load publishes; the first load's reconcile then catches up.
        #expect(DocumentLoad.mayPublish(parsingB, of: tickets, loadedSHA: "B", liveSHA: "A", documentShown: false))
        // An older ticket never publishes.
        let newer = tickets.issue()
        #expect(!DocumentLoad.mayPublish(parsingB, of: tickets, loadedSHA: "B", liveSHA: "B", documentShown: true))
        #expect(DocumentLoad.mayPublish(newer, of: tickets, loadedSHA: "B", liveSHA: "B", documentShown: true))
    }

    @Test func cancelledParseOfLargeFileThrowsCancellation() async {
        let data = LargeKML.data(placemarks: 100_000)
        let task = Task.detached { () throws -> Bool in
            while !Task.isCancelled {
                await Task.yield()
            }
            _ = try DocumentLoad.parse(data)
            return true
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

/// Synthetic big KML for cancellation tests.
enum LargeKML {
    static func data(placemarks: Int) -> Data {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><kml xmlns=\"http://www.opengis.net/kml/2.2\"><Document>"
        xml.reserveCapacity(placemarks * 90)
        for index in 0 ..< placemarks {
            xml += "<Placemark><name>P\(index)</name><Point><coordinates>1,2,0</coordinates></Point></Placemark>"
        }
        xml += "</Document></kml>"
        return Data(xml.utf8)
    }
}
