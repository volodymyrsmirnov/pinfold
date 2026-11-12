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

    @Test func reykjavikFindsReykjavík() {
        #expect(SearchText.contains("Reykjavík", query: "Reykjavik"))
    }

    @Test func accentedQueryFindsPlainText() {
        #expect(SearchText.contains("Cafe Central", query: "café"))
    }

    @Test func caseStillIgnored() {
        #expect(SearchText.contains("ÉCOLE", query: "école"))
    }

    @Test func foldIsCaseAccentAndWidthInsensitive() {
        #expect(SearchText.fold("Reykjavík") == SearchText.fold("REYKJAVIK"))
        #expect(SearchText.fold("ＡＢＣ") == SearchText.fold("abc"))
    }

    @Test func foldedContainsMatchesPrecomputedText() {
        #expect(SearchText.foldedContains(SearchText.fold("Reykjavík Harbour"), foldedQuery: SearchText.fold("harbor")) == false)
        #expect(SearchText.foldedContains(SearchText.fold("Reykjavík Harbour"), foldedQuery: SearchText.fold("REYKJAVIK")))
    }
}
