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
