import Foundation
@testable import PinfoldCore
import Testing

struct LargeFileTests {
    /// Regression guard against quadratic parsing behavior. 50k point placemarks must parse
    /// in well under the bound; the threshold is generous on purpose — it catches an O(n²)
    /// regression, not micro-perf drift. The document is generated in code to avoid checking
    /// in a multi-megabyte fixture.
    @Test(.timeLimit(.minutes(1)))
    func parse_50kPlacemarksUnderTimeBound() throws {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2">
        <Document><name>Large</name>
        """
        xml.reserveCapacity(50000 * 120)
        for i in 0 ..< 50000 {
            let lon = -180.0 + Double(i % 360)
            let lat = -90.0 + Double(i % 180)
            xml += """
            <Placemark><name>P\(i)</name>\
            <Point><coordinates>\(lon),\(lat),0</coordinates></Point></Placemark>
            """
        }
        xml += "</Document></kml>"
        let data = Data(xml.utf8)

        let clock = ContinuousClock()
        var parsed: ParsedKML?
        let elapsed = try clock.measure {
            parsed = try KMLReader.read(data: data)
        }

        #expect(parsed?.document.pointCount == 50000)
        #expect(elapsed < .seconds(10), "parse took \(elapsed), expected < 10s")
    }
}
