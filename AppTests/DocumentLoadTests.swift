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
