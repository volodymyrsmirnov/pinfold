import Foundation
@testable import PinfoldCore
import Testing

struct CorpusTests {
    static let fixtures = [
        "KML_Samples.kml", "Munich Sole.kml", "Munich Sole.kmz",
        "Rome.kml", "Rome.kmz", "Iceland.kml", "Iceland.kmz",
        "iceland-trip-2026.kml", "schemadata.kml",
    ]

    @Test(arguments: fixtures)
    func everyFixtureReadsWithoutThrowing(name: String) throws {
        let parsed = try KMLReader.read(data: Fixture.data(name))
        #expect(parsed.document.name?.isEmpty == false)
        #expect(parsed.document.placemarkCount > 0)
        for pm in parsed.document.root.allPlacemarks {
            if let c = pm.coordinate {
                #expect(c.latitude >= -90 && c.latitude <= 90)
                #expect(c.longitude >= -180 && c.longitude <= 180)
            }
        }
    }
}
