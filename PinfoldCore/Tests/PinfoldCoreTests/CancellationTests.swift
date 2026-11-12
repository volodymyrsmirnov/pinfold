import Foundation
@testable import PinfoldCore
import Testing
import ZIPFoundation

struct CancellationTests {
    private func largeKML(placemarks: Int) -> Data {
        var xml = "<?xml version=\"1.0\"?><kml xmlns=\"http://www.opengis.net/kml/2.2\"><Document>"
        for i in 0 ..< placemarks {
            xml += "<Placemark><name>P\(i)</name><Point><coordinates>1,2,0</coordinates></Point></Placemark>"
        }
        xml += "</Document></kml>"
        return Data(xml.utf8)
    }

    private func makeZip(_ entries: [(path: String, data: Data)]) throws -> Data {
        let archive = try Archive(accessMode: .create)
        for (path, data) in entries {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
                data.subdata(in: Int(position) ..< (Int(position) + size))
            }
        }
        return archive.data!
    }

    private let minimalKML = Data("<kml><Document><name>Z</name></Document></kml>".utf8)

    @Test(.timeLimit(.minutes(1)))
    func parseInCancelledTaskThrowsCancellationError() async {
        let data = largeKML(placemarks: 20000)
        let task = Task { () throws -> KMLDocument in
            while !Task.isCancelled {
                await Task.yield()
            }
            return try KMLParser.parse(data: data)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func parseWithoutCancellationIsUnaffected() async throws {
        let data = largeKML(placemarks: 2000)
        let document = try await Task { try KMLParser.parse(data: data) }.value
        #expect(document.pointCount == 2000)
    }

    @Test(.timeLimit(.minutes(1)))
    func extractInCancelledTaskThrowsCancellationError() async throws {
        let zip = try makeZip([("doc.kml", minimalKML), ("a.png", Data([1])), ("b.png", Data([2]))])
        let task = Task { () throws -> KMZContents in
            while !Task.isCancelled {
                await Task.yield()
            }
            return try KMZArchive.extract(zip)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test(.timeLimit(.minutes(1)))
    func extractResourcesCancelledMidwayRemovesWrittenFiles() async throws {
        let zip = try makeZip([("doc.kml", minimalKML), ("a.png", Data([1])), ("b.png", Data([2])),
                               ("c.png", Data([3]))])
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CancellationTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let task = Task { () throws -> [String: String] in
            var calls = 0
            return try KMZArchive.extractResources(zip, into: directory, filenameFor: { key in
                calls += 1
                if calls == 2 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
                return key
            })
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(left.isEmpty)
    }

    @Test func extractRootInCancelledTaskThrowsCancellationError() async throws {
        let zip = try makeZip([("doc.kml", minimalKML)])
        let task = Task { () throws -> Data in
            while !Task.isCancelled {
                await Task.yield()
            }
            return try KMZArchive.extractRoot(zip).rootKML
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
