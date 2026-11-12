@testable import Pinfold
import PinfoldCore
import Testing

/// Tests for `SearchCorpus` — the per-document folded searchable text for in-file search.
struct SearchCorpusTests {
    private func root(_ placemarks: [KMLPlacemark]) -> KMLContainer {
        KMLContainer(id: "root", name: nil, children: [], placemarks: placemarks)
    }

    private func placemark(id: String, name: String?, html: String?) -> KMLPlacemark {
        KMLPlacemark(
            id: id, name: name, descriptionHTML: html, styleUrl: nil, coordinate: nil,
            extendedData: [], photoLinks: []
        )
    }

    @Test func stripsMarkupBeforeFolding() {
        let corpus = SearchCorpus(root: root([
            placemark(id: "p1", name: "Camp", html: "<p>Quiet <b>Riverside</b> spécial</p>"),
        ]))
        #expect(corpus.matches(placemarkID: "p1", foldedQuery: SearchText.fold("riverside")))
        #expect(corpus.matches(placemarkID: "p1", foldedQuery: SearchText.fold("special")))
        #expect(!corpus.matches(placemarkID: "p1", foldedQuery: SearchText.fold("<b>")))
        #expect(!corpus.matches(placemarkID: "missing", foldedQuery: "camp"))
    }

    @Test func capsVeryLongDescriptions() {
        let html = String(repeating: "word ", count: 1000) + "needleatthetail"
        let corpus = SearchCorpus(root: root([placemark(id: "p1", name: "Long", html: html)]))
        #expect(corpus.matches(placemarkID: "p1", foldedQuery: "word"))
        #expect(!corpus.matches(placemarkID: "p1", foldedQuery: "needleatthetail"))
    }
}
