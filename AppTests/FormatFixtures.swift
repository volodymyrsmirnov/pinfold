import Foundation

/// Loads the GPX fixture straight from the source tree. XcodeGen classifies `.gpx` as a
/// source-like file type, so `sample.gpx` is not copied into the test bundle the way the
/// other fixtures are and `AppFixture.data(_:)` cannot find it.
enum FormatFixture {
    static func gpx() throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // AppTests
            .appendingPathComponent("Fixtures/sample.gpx")
        return try Data(contentsOf: url)
    }
}
