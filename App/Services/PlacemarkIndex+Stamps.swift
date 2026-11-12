import Foundation

/// Small marker files kept beside the search index in `resources/`. Both are derivable and
/// per-device; deleting `resources/` (as a snapshot replacement does) clears them.
extension PlacemarkIndex {
    /// Records the SHA-256 of the original the index (and the rest of `resources/`) was built
    /// from. An index *without* this file counts as current, so existing installs are not all
    /// re-parsed a second time; the scanner stamps such an index on its next pass instead.
    static let sourceStampFilename = "placemarks-index.source"
    /// Records the SHA-256 of an original that failed to parse, so the scanner stops
    /// re-reading it on every pass until its content changes.
    static let parseFailureFilename = "placemarks-index.parse-failed"

    /// The SHA the index was built from, or `nil` when unstamped.
    static func sourceStamp(in resourcesDir: URL) -> String? {
        readMarker(sourceStampFilename, in: resourcesDir)
    }

    /// Stamps the index as built from the original with `sha`. Best effort: a failure only
    /// means the next pass stamps it again.
    static func writeSourceStamp(_ sha: String, to resourcesDir: URL) {
        writeMarker(sha, named: sourceStampFilename, in: resourcesDir)
    }

    /// The SHA of the original last recorded as unparseable, or `nil`.
    static func parseFailureMarker(in resourcesDir: URL) -> String? {
        readMarker(parseFailureFilename, in: resourcesDir)
    }

    /// Records that the original with `sha` could not be parsed. Creates `resourcesDir`.
    static func writeParseFailureMarker(_ sha: String, to resourcesDir: URL) {
        writeMarker(sha, named: parseFailureFilename, in: resourcesDir)
    }

    /// Removes the unparseable marker (the original now parses).
    static func clearParseFailureMarker(in resourcesDir: URL) {
        try? FileManager.default.removeItem(at: resourcesDir.appendingPathComponent(parseFailureFilename))
    }

    private static func readMarker(_ name: String, in resourcesDir: URL) -> String? {
        guard let data = try? Data(contentsOf: resourcesDir.appendingPathComponent(name)),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func writeMarker(_ value: String, named name: String, in resourcesDir: URL) {
        try? FileManager.default.createDirectory(at: resourcesDir, withIntermediateDirectories: true)
        try? Data(value.utf8).write(to: resourcesDir.appendingPathComponent(name), options: .atomic)
    }
}
