import Foundation
@testable import PinfoldCore
import Testing

/// CB-6 (A12a): folder descriptions live in the model.
struct ContainerDescriptionTests {
    private func parse(_ xml: String) throws -> KMLDocument {
        try KMLParser.parse(data: Data(xml.utf8))
    }

    @Test func folderDescriptionIsKept() throws {
        let doc = try parse("""
        <kml><Document><name>D</name>
          <Folder><name>F</name><description><![CDATA[<b>About</b> this folder]]></description>
            <Placemark><name>P</name><Point><coordinates>1,2</coordinates></Point></Placemark>
          </Folder>
        </Document></kml>
        """)
        let folder = try #require(doc.root.children.first)
        #expect(folder.descriptionHTML == "<b>About</b> this folder")
        // The folder text must not leak onto the document or the placemark.
        #expect(doc.descriptionHTML == nil)
        #expect(doc.root.allPlacemarks.first?.descriptionHTML == nil)
    }

    @Test func nestedFolderDescriptionsAreKept() throws {
        let doc = try parse("""
        <kml><Document><name>D</name><description>doc</description>
          <Folder><name>Outer</name><description>outer text</description>
            <Folder><name>Inner</name><description>inner <i>text</i></description>
              <Placemark><name>P</name><Point><coordinates>1,2</coordinates></Point></Placemark>
            </Folder>
          </Folder>
          <Folder><name>NoDesc</name>
            <ScreenOverlay><description>overlay</description></ScreenOverlay>
          </Folder>
        </Document></kml>
        """)
        let outer = try #require(doc.root.children.first)
        let inner = try #require(outer.children.first)
        #expect(outer.descriptionHTML == "outer text")
        #expect(inner.descriptionHTML == "inner <i>text</i>")
        #expect(doc.root.children.last?.descriptionHTML == nil)
        #expect(doc.descriptionHTML == "doc")
    }

    @Test func collapsedRootStillExposesDocumentDescription() throws {
        let doc = try parse("""
        <kml><Document><name>D</name><description>Doc text</description>
          <Placemark><name>P</name><Point><coordinates>1,2</coordinates></Point></Placemark>
        </Document></kml>
        """)
        #expect(doc.descriptionHTML == "Doc text")
        #expect(doc.root.descriptionHTML == "Doc text")
    }

    @Test func containerInitDefaultsDescriptionToNil() {
        let container = KMLContainer(id: "c", name: nil, children: [], placemarks: [])
        #expect(container.descriptionHTML == nil)
    }
}
