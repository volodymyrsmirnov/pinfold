@testable import PinfoldCore
import Testing

struct ModelTests {
    private func sampleDoc() -> KMLDocument {
        let p1 = KMLPlacemark(id: "p1", name: "A", descriptionHTML: nil,
                              styleUrl: "#m1", coordinate: Coordinate(longitude: 1, latitude: 2),
                              extendedData: [], photoLinks: [])
        let p2 = KMLPlacemark(id: "p2", name: "B", descriptionHTML: nil,
                              styleUrl: "#s1", coordinate: nil, hasPoint: false,
                              extendedData: [KMLDataItem(name: "day", value: "1")], photoLinks: [])
        let inner = KMLContainer(id: "c1", name: "Inner", children: [], placemarks: [p2])
        let root = KMLContainer(id: "c0", name: "Root", children: [inner], placemarks: [p1])
        let styles = [
            "s1": KMLStyle(id: "s1", iconHref: "a.png", iconColor: "ff0000ff", iconScale: 1),
            "sNormal": KMLStyle(id: "sNormal", iconHref: "n.png", iconColor: nil, iconScale: nil),
        ]
        let styleMaps = ["m1": "#sNormal"]
        return KMLDocument(name: "Doc", descriptionHTML: nil, root: root,
                           styles: styles, styleMaps: styleMaps)
    }

    @Test func pointCountCountsOnlyPlacemarksWithExplicitPoint() {
        #expect(sampleDoc().pointCount == 1) // only p1 has an explicit Point (hasPoint)
    }

    @Test func placemarkCountCountsAllPlacemarks() {
        #expect(sampleDoc().placemarkCount == 2)
    }

    @Test func resolvesDirectStyleUrl() {
        #expect(sampleDoc().resolvedStyle(forStyleUrl: "#s1")?.iconHref == "a.png")
    }

    @Test func resolvesStyleMapToNormalStyle() {
        #expect(sampleDoc().resolvedStyle(forStyleUrl: "#m1")?.iconHref == "n.png")
    }

    @Test func resolveReturnsNilForUnknownOrNil() {
        let doc = sampleDoc()
        #expect(doc.resolvedStyle(forStyleUrl: "#nope") == nil)
        #expect(doc.resolvedStyle(forStyleUrl: nil) == nil)
    }
}
