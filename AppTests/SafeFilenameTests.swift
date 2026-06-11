import Foundation
@testable import Pinfold
import Testing

/// Tests for `SafeFilename.sanitize` — the single sanitizer applied to attacker-controlled
/// filenames at import choke points.
struct SafeFilenameTests {
    @Test func sanitize_takesFinalPathComponent() {
        #expect(SafeFilename.sanitize("images/evil.kml") == "evil.kml")
        #expect(SafeFilename.sanitize("../x.kml") == "x.kml")
        #expect(SafeFilename.sanitize("/a/b/c/deep.kmz") == "deep.kmz")
    }

    @Test func sanitize_stripsControlAndSeparatorChars() {
        // Backslashes are path separators on some hosts → treated as separators (last
        // component wins). NUL and newlines must never survive into a filename.
        #expect(SafeFilename.sanitize("a\\b\\evil.kml") == "evil.kml")
        #expect(!SafeFilename.sanitize("evil\u{0}.kml").contains("\u{0}"))
        #expect(!SafeFilename.sanitize("line\nbreak.kml").contains("\n"))
        // Control chars are replaced with "-", not dropped silently into adjacency.
        #expect(SafeFilename.sanitize("tab\there.kml") == "tab-here.kml")
    }

    @Test func sanitize_stripsLeadingDots() {
        #expect(SafeFilename.sanitize(".hidden.kml") == "hidden.kml")
        #expect(SafeFilename.sanitize("...weird.kml") == "weird.kml")
    }

    @Test func sanitize_capsLengthPreservingExtension() {
        let stem = String(repeating: "a", count: 300)
        let result = SafeFilename.sanitize("\(stem).kml")
        #expect(result.utf8.count <= 255, "result must be <= 255 UTF-8 bytes")
        #expect(result.hasSuffix(".kml"), "extension must be preserved")
    }

    @Test func sanitize_emptyOrDegenerateFallsBack() {
        // Fallback is the literal "file" (no extension assumption) — deterministic.
        #expect(SafeFilename.sanitize("") == "file")
        #expect(SafeFilename.sanitize("/") == "file")
        #expect(SafeFilename.sanitize("...") == "file")
    }
}
