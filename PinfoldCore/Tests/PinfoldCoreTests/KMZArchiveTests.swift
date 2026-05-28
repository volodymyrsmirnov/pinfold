import Foundation
@testable import PinfoldCore
import Testing

struct KMZArchiveTests {
    @Test func detectsKMZMagic() throws {
        #expect(try KMZArchive.isKMZ(Fixture.data("Rome.kmz")) == true)
        #expect(try KMZArchive.isKMZ(Fixture.data("Rome.kml")) == false)
    }

    @Test func extractsRootKMLAndResources() throws {
        let contents = try KMZArchive.extract(Fixture.data("Rome.kmz"))
        let doc = try KMLParser.parse(data: contents.rootKML)
        #expect(doc.name == "Rome")
        #expect(contents.resources.keys.contains("images/icon-1.png"))
        #expect(contents.resources["images/icon-1.png"]?.isEmpty == false)
    }

    @Test func munichKMZHasFiveIconResources() throws {
        let contents = try KMZArchive.extract(Fixture.data("Munich Sole.kmz"))
        let icons = contents.resources.keys.filter { $0.hasPrefix("images/") }
        #expect(icons.count == 5)
    }

    @Test func rootKMLPathIsExposedOnContents() throws {
        let contents = try KMZArchive.extract(Fixture.data("Rome.kmz"))
        #expect(contents.rootKMLPath == "doc.kml")
    }

    @Test func extractThrowsNotAZipArchiveForPlainKML() throws {
        #expect(throws: KMZArchiveError.notAZipArchive) {
            try KMZArchive.extract(Fixture.data("Rome.kml"))
        }
    }

    @Test func isKMZReturnsFalseForEmptyData() {
        #expect(KMZArchive.isKMZ(Data()) == false)
    }

    @Test func extractRejectsArchiveExceedingByteCap() throws {
        #expect(throws: KMZArchiveError.archiveTooLarge) {
            try KMZArchive.extract(Fixture.data("Rome.kmz"), maxUncompressedBytes: 8)
        }
    }

    @Test func extractRejectsArchiveExceedingEntryCap() throws {
        #expect(throws: KMZArchiveError.archiveTooLarge) {
            try KMZArchive.extract(Fixture.data("Rome.kmz"), maxEntryCount: 0)
        }
    }

    @Test func extractSucceedsWithinDefaultCaps() throws {
        // The generous defaults must never reject a normal archive.
        let contents = try KMZArchive.extract(Fixture.data("Rome.kmz"))
        #expect(contents.resources.isEmpty == false)
    }
}
