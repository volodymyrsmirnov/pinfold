import Testing
import Foundation
@testable import PinfoldCore

@Suite struct KMLReaderTests {
    @Test func readsPlainKML() throws {
        let parsed = try KMLReader.read(data: try Fixture.data("Rome.kml"))
        #expect(parsed.document.name == "Rome")
        #expect(parsed.embeddedResources.isEmpty)
        #expect(parsed.document.pointCount > 0)
    }

    @Test func readsKMZWithResources() throws {
        let parsed = try KMLReader.read(data: try Fixture.data("Rome.kmz"))
        #expect(parsed.document.name == "Rome")
        #expect(parsed.embeddedResources.keys.contains("images/icon-1.png"))
    }

    @Test func kmlAndKmzProduceSamePlacemarkCount() throws {
        let fromKML = try KMLReader.read(data: try Fixture.data("Rome.kml"))
        let fromKMZ = try KMLReader.read(data: try Fixture.data("Rome.kmz"))
        #expect(fromKML.document.placemarkCount == fromKMZ.document.placemarkCount)
    }

    @Test func kmzReadExposesRootKMLPath() throws {
        let parsed = try KMLReader.read(data: try Fixture.data("Rome.kmz"))
        #expect(parsed.rootKMLPath == "doc.kml")
    }

    @Test func plainKMLReadHasNilRootKMLPath() throws {
        let parsed = try KMLReader.read(data: try Fixture.data("Rome.kml"))
        #expect(parsed.rootKMLPath == nil)
    }
}
