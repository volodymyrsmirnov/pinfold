import Foundation
@testable import PinfoldCore
import Testing

/// Unique `KMLDataItem.id`s must stay as they were (`name`, `name#2`, ...) and cost O(1) per
/// item: 40k repeated `<Data>` items once took 17 s because each rebuilt the set of used ids.
struct DataItemIDTests {
    private func items(_ data: String) throws -> [KMLDataItem] {
        let xml = """
        <kml><Document><Placemark><name>P</name><ExtendedData>\(data)</ExtendedData></Placemark></Document></kml>
        """
        let doc = try KMLParser.parse(data: Data(xml.utf8))
        return try #require(doc.root.allPlacemarks.first).extendedData
    }

    private func data(_ name: String) -> String {
        "<Data name=\"\(name)\"><value>v</value></Data>"
    }

    @Test func repeatedNamesGetSequentialSuffixes() throws {
        let ids = try items(data("a") + data("a") + data("b") + data("a")).map(\.id)
        #expect(ids == ["a", "a#2", "b", "a#3"])
    }

    @Test func literalNameCollidingWithGeneratedIDIsSkipped() throws {
        // "a#2" is taken by the literal item, so the second plain "a" must become "a#3".
        let ids = try items(data("a") + data("a#2") + data("a") + data("a#2")).map(\.id)
        #expect(ids == ["a", "a#2", "a#3", "a#2#2"])
    }

    @Test func generatedIDThatLaterMatchesALiteralNameIsSkipped() throws {
        let ids = try items(data("a") + data("a") + data("a#2")).map(\.id)
        #expect(ids == ["a", "a#2", "a#2#2"])
    }

    @Test func fortyThousandRepeatedItemsParseQuickly() throws {
        let xml = data("k")
        let body = String(repeating: xml, count: 40000)
        let start = Date()
        let result = try items(body)
        let elapsed = Date().timeIntervalSince(start)
        #expect(result.count == 40000)
        #expect(Set(result.map(\.id)).count == 40000)
        #expect(result.last?.id == "k#40000")
        #expect(elapsed < 1.0, "took \(elapsed) s")
    }
}
