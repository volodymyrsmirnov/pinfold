import Foundation
@testable import Pinfold
import PinfoldCore
import Testing

/// Which Details values become links, and what a place's Share sends.
struct WebLinkTests {
    @Test func acceptsPlainWebAddresses() {
        #expect(WebLink.url(from: "https://maps.google.com/?cid=123")?.host() == "maps.google.com")
        #expect(WebLink.url(from: "  http://example.com/a  ") != nil)
        #expect(WebLink.url(from: "HTTPS://Example.com") != nil)
    }

    @Test func rejectsEverythingElse() {
        for value in [
            "javascript:alert(1)", "file:///etc/hosts", "mailto:a@b.c", "https://", "http:///path",
            "see https://example.com", "https://a.com,https://b.com and more", "Transport", "",
        ] {
            #expect(WebLink.url(from: value) == nil, "\(value)")
        }
    }

    @Test func placeShareURLKeepsReservedCharactersInTheName() throws {
        let hit = PlacemarkIndex.Hit(folderName: "f", key: "k", name: "Rock & Roll = 1+1", lat: 50.8467, lon: 4.3517)
        let url = try #require(PlaceRef(hit).shareURL)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(url.host() == "maps.apple.com")
        #expect(items.first { $0.name == "q" }?.value == "Rock & Roll = 1+1")
        #expect(items.first { $0.name == "ll" }?.value == "50.846700,4.351700")
        #expect(items.count == 2)
    }

    @Test func placeWithoutCoordinateHasNoShareURL() {
        let hit = PlacemarkIndex.Hit(folderName: "f", key: "k", name: "Nowhere", lat: nil, lon: nil)
        #expect(PlaceRef(hit).shareURL == nil)
    }
}
