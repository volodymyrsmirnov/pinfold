import Foundation
@testable import Pinfold
import Testing

struct DroppedFilesTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropped-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func acceptsSupportedExtensionsOnly() {
        for name in ImportFormats.originalExtensions {
            #expect(DroppedFiles.accepts(URL(fileURLWithPath: "/x/a.\(name)")))
            #expect(DroppedFiles.accepts(URL(fileURLWithPath: "/x/A.\(name.uppercased())")))
        }
        #expect(!DroppedFiles.accepts(URL(fileURLWithPath: "/x/photo.png")))
        #expect(!DroppedFiles.accepts(URL(fileURLWithPath: "/x/noextension")))
        #expect(!DroppedFiles.accepts(URL(fileURLWithPath: "/x/archive.kml.txt")))
    }

    @Test func mixedDropKeepsTheSupportedFiles() throws {
        let source = try tempDir()
        let dest = try tempDir()
        for name in ["a.kml", "b.kmz", "c.png"] {
            try Data(name.utf8).write(to: source.appendingPathComponent(name))
        }
        let urls = ["a.kml", "b.kmz", "c.png"].map { source.appendingPathComponent($0) }

        let staged = DroppedFiles.stage(urls, into: dest)

        #expect(staged.map(\.lastPathComponent) == ["a.kml", "b.kmz"])
        for url in staged {
            #expect(url.path.hasPrefix(dest.path))
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
        // The copy survives removal of the source, as a provider's URL would not.
        try FileManager.default.removeItem(at: source)
        #expect(try Data(contentsOf: staged[0]) == Data("a.kml".utf8))
    }
}
