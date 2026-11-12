import Foundation
@testable import PinfoldCore
import Testing
import ZIPFoundation

struct ArchiveErrorDescriptionTests {
    private func makeZip(_ entries: [(path: String, data: Data)]) throws -> Data {
        let archive = try Archive(accessMode: .create)
        for (path, data) in entries {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
                data.subdata(in: Int(position) ..< (Int(position) + size))
            }
        }
        return archive.data!
    }

    @Test func corruptZipSurfacesReadableError() throws {
        let garbage = Data([0x50, 0x4B, 0x03, 0x04]) + Data(repeating: 0x7F, count: 64)
        do {
            _ = try KMLReader.read(data: garbage)
            Issue.record("expected an error")
        } catch let error as KMZArchiveError {
            guard case .corruptArchive = error else {
                Issue.record("expected corruptArchive, got \(error)")
                return
            }
            let message = error.localizedDescription
            #expect(message.contains("KMZ"))
            #expect(!message.contains("ZIPFoundation"))
            #expect(!message.contains("The operation couldn"))
        }
        #expect(throws: KMZArchiveError.self) { try KMLReader.readDocument(data: garbage) }
    }

    @Test func noKMLEntryDescription() throws {
        #expect(KMZArchiveError.noKMLEntry.errorDescription == "This KMZ has no KML inside.")
        #expect(KMZArchiveError.notAZipArchive.errorDescription == "This file is not a readable zip archive.")
        let zip = try makeZip([("images/a.png", Data([1]))])
        do {
            _ = try KMLReader.readDocument(data: zip)
            Issue.record("expected an error")
        } catch {
            #expect(error.localizedDescription == "This KMZ has no KML inside.")
        }
    }

    @Test func kmzEntryParseFailureNamesTheEntryAndLine() throws {
        let truncated = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2">
          <Document><name>Bad
        """.utf8)
        let zip = try makeZip([("doc.kml", truncated)])
        for attempt in [{ _ = try KMLReader.read(data: zip) }, { _ = try KMLReader.readDocument(data: zip) }] {
            do {
                try attempt()
                Issue.record("expected an error")
            } catch let error as KMLReadError {
                let message = error.localizedDescription
                #expect(message.hasPrefix("doc.kml: "))
                guard case let .kmzEntryParseFailed(_, underlying) = error else {
                    Issue.record("wrong case")
                    return
                }
                #expect(message.contains(underlying.localizedDescription))
                // Line-number wording is CORE-A's (KMLParseError LocalizedError); not asserted here.
            }
        }
    }

    @Test func fileTooLargeDescription() {
        #expect(KMLReadError.fileTooLarge.errorDescription == "This file is too large to open.")
    }
}
