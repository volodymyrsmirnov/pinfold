import Foundation
@testable import PinfoldCore
import Testing

/// GeoJSON properties that map onto KML-only placemark and document fields.
struct GeoJSONKMLFieldTests {
    private let point = #"{"type":"Point","coordinates":[1,2]}"#

    private func placemark(_ properties: String) throws -> (KMLDocument, KMLPlacemark) {
        let json = #"{"type":"Feature","geometry":\#(point),"properties":\#(properties)}"#
        let doc = try KMLReader.readDocument(data: Data(json.utf8))
        return try (doc, #require(doc.root.placemarks.first))
    }

    private func dataNames(_ mark: KMLPlacemark) -> [String] {
        mark.extendedData.map(\.name)
    }

    @Test func markerSizeBecomesIconScale() throws {
        let (smallDoc, small) = try placemark(#"{"marker-size":"small"}"#)
        #expect(smallDoc.resolvedStyle(forStyleUrl: small.styleUrl)?.iconScale == 0.75)
        let (largeDoc, large) = try placemark(#"{"marker-size":"large"}"#)
        #expect(largeDoc.resolvedStyle(forStyleUrl: large.styleUrl)?.iconScale == 1.5)
        // `medium` is the default size, so on its own it needs no style.
        let (mediumDoc, medium) = try placemark(#"{"marker-size":"medium"}"#)
        #expect(medium.styleUrl == nil)
        #expect(mediumDoc.styles.isEmpty)
        #expect(dataNames(medium).isEmpty)
    }

    @Test func markerSymbolIsKeptAsData() throws {
        let (_, mark) = try placemark(#"{"marker-symbol":"rocket"}"#)
        #expect(mark.extendedData.map(\.value) == ["rocket"])
        #expect(dataNames(mark) == ["marker-symbol"])
    }

    @Test func iconURLBecomesIconHref() throws {
        let (doc, mark) = try placemark(##"{"icon":"https://example.com/pin.png","marker-color":"#ff0000"}"##)
        let style = try #require(doc.resolvedStyle(forStyleUrl: mark.styleUrl))
        #expect(style.iconHref == "https://example.com/pin.png")
        #expect(style.iconColor == "ff0000ff")
        #expect(dataNames(mark).isEmpty)
    }

    @Test func nonURLIconStaysData() throws {
        let (doc, mark) = try placemark(#"{"icon":"pin"}"#)
        #expect(doc.styles.isEmpty)
        #expect(dataNames(mark) == ["icon"])
    }

    @Test func mediaLinksBecomePhotos() throws {
        let (_, mark) = try placemark(#"{"gx_media_links":"https://a.example/1.jpg  https://a.example/2.jpg"}"#)
        #expect(mark.photoLinks == ["https://a.example/1.jpg", "https://a.example/2.jpg"])
        #expect(dataNames(mark).isEmpty)
    }

    @Test func imageAndPhotoKeysBecomePhotos() throws {
        let (_, mark) = try placemark(
            #"{"photo":"https://a.example/p.jpg","images":["https://a.example/i.png"],"image":"http://a.example/x.jpg"}"#
        )
        // Keys are taken in sorted order, matching extended data.
        #expect(mark.photoLinks == [
            "http://a.example/x.jpg", "https://a.example/i.png", "https://a.example/p.jpg",
        ])
        #expect(dataNames(mark).isEmpty)
    }

    @Test func photoKeyWithoutURLsStaysData() throws {
        let (_, mark) = try placemark(#"{"photo":"IMG_0042.jpg","image":"yes https://a.example/x.jpg"}"#)
        #expect(mark.photoLinks.isEmpty)
        #expect(dataNames(mark) == ["image", "photo"])
    }

    @Test func snippetAddressAndPhoneBecomeFields() throws {
        let (_, mark) = try placemark(#"{"snippet":"Short teaser","address":"1 Main St","phoneNumber":"+1 555"}"#)
        #expect(mark.snippet == "Short teaser")
        #expect(mark.address == "1 Main St")
        #expect(mark.phoneNumber == "+1 555")
        #expect(dataNames(mark).isEmpty)
    }

    @Test func phoneIsTheFallbackPhoneNumber() throws {
        let (_, mark) = try placemark(#"{"phone":"+1 555"}"#)
        #expect(mark.phoneNumber == "+1 555")
        #expect(dataNames(mark).isEmpty)
        let (_, both) = try placemark(#"{"phone":"+1 111","phoneNumber":"+1 222"}"#)
        #expect(both.phoneNumber == "+1 222")
        #expect(dataNames(both) == ["phone"])
    }

    @Test func collectionDescriptionBecomesDocumentDescription() throws {
        let json = #"{"type":"FeatureCollection","description":"Trails & huts","features":[]}"#
        let doc = try KMLReader.readDocument(data: Data(json.utf8))
        #expect(doc.descriptionHTML == "Trails &amp; huts")
        let html = #"{"type":"FeatureCollection","description":"<p>Hi</p>","features":[]}"#
        #expect(try KMLReader.readDocument(data: Data(html.utf8)).descriptionHTML == "<p>Hi</p>")
    }
}
