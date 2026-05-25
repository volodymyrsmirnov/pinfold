import Testing
import Foundation
@testable import PinfoldCore

@Suite struct KMZArchiveTests {
    @Test func detectsKMZMagic() throws {
        #expect(KMZArchive.isKMZ(try Fixture.data("Rome.kmz")) == true)
        #expect(KMZArchive.isKMZ(try Fixture.data("Rome.kml")) == false)
    }

    @Test func extractsRootKMLAndResources() throws {
        let contents = try KMZArchive.extract(try Fixture.data("Rome.kmz"))
        let doc = try KMLParser.parse(data: contents.rootKML)
        #expect(doc.name == "Rome")
        #expect(contents.resources.keys.contains("images/icon-1.png"))
        #expect(contents.resources["images/icon-1.png"]?.isEmpty == false)
    }

    @Test func munichKMZHasFiveIconResources() throws {
        let contents = try KMZArchive.extract(try Fixture.data("Munich Sole.kmz"))
        let icons = contents.resources.keys.filter { $0.hasPrefix("images/") }
        #expect(icons.count == 5)
    }

    @Test func rootKMLPathIsExposedOnContents() throws {
        let contents = try KMZArchive.extract(try Fixture.data("Rome.kmz"))
        #expect(contents.rootKMLPath == "doc.kml")
    }

    @Test func extractThrowsNotAZipArchiveForPlainKML() throws {
        #expect(throws: KMZArchiveError.notAZipArchive) {
            try KMZArchive.extract(try Fixture.data("Rome.kml"))
        }
    }

    @Test func isKMZReturnsFalseForEmptyData() {
        #expect(KMZArchive.isKMZ(Data()) == false)
    }
}
