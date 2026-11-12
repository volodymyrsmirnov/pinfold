@testable import Pinfold
import Testing

/// Tests for `SearchText.contains`, the single matching primitive behind every search surface.
struct SearchTextTests {
    @Test func caseInsensitiveMatch() {
        #expect(SearchText.contains("Hello World", query: "world"))
        #expect(SearchText.contains("Hello World", query: "HELLO"))
    }

    @Test func noMatch() {
        #expect(!SearchText.contains("Hello World", query: "mars"))
    }
}
