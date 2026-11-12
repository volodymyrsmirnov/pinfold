import Foundation
@testable import PinfoldCore
import Testing

/// CB-7 (A13a): Snippet, address, phoneNumber and `<Data><displayName>` capture, plus
/// distinct ids for repeated data names.
struct DataCaptureTests {
    private func onlyPlacemark(_ body: String) throws -> KMLPlacemark {
        let xml = "<kml><Document><name>D</name><Placemark><name>P</name>\(body)</Placemark></Document></kml>"
        let doc = try KMLParser.parse(data: Data(xml.utf8))
        return try #require(doc.root.allPlacemarks.first)
    }

    @Test func snippetIsCaptured() throws {
        let pm = try onlyPlacemark("<Snippet maxLines=\"2\">Short teaser</Snippet><Point><coordinates>1,2</coordinates></Point>")
        #expect(pm.snippet == "Short teaser")
        let lower = try onlyPlacemark("<snippet>lower case</snippet><Point><coordinates>1,2</coordinates></Point>")
        #expect(lower.snippet == "lower case")
    }

    @Test func snippetCDATAIsTrimmed() throws {
        let pm = try onlyPlacemark("<Snippet><![CDATA[  padded  ]]></Snippet>")
        #expect(pm.snippet == "padded")
    }

    @Test func emptySnippetIsNil() throws {
        let pm = try onlyPlacemark("<Snippet maxLines=\"0\"></Snippet>")
        #expect(pm.snippet == nil)
    }

    @Test func addressAndPhoneNumberAreCaptured() throws {
        let pm = try onlyPlacemark("""
        <address>1600 Amphitheatre Pkwy, Mountain View</address>
        <phoneNumber>+1 650-253-0000</phoneNumber>
        <Point><coordinates>1,2</coordinates></Point>
        """)
        #expect(pm.address == "1600 Amphitheatre Pkwy, Mountain View")
        #expect(pm.phoneNumber == "+1 650-253-0000")
    }

    @Test func missingFieldsAreNil() throws {
        let pm = try onlyPlacemark("<Point><coordinates>1,2</coordinates></Point>")
        #expect(pm.snippet == nil)
        #expect(pm.address == nil)
        #expect(pm.phoneNumber == nil)
    }

    @Test func dataDisplayNameIsCaptured() throws {
        let pm = try onlyPlacemark("""
        <ExtendedData>
          <Data name="opening_hours"><displayName>Opening hours</displayName><value>9-5</value></Data>
          <Data name="plain"><value>x</value></Data>
        </ExtendedData>
        """)
        #expect(pm.extendedData.count == 2)
        #expect(pm.extendedData[0].name == "opening_hours")
        #expect(pm.extendedData[0].displayName == "Opening hours")
        #expect(pm.extendedData[0].value == "9-5")
        #expect(pm.extendedData[1].displayName == nil)
    }

    @Test func schemaFieldDisplayNameIsNotCaptured() throws {
        let xml = """
        <kml><Document><name>D</name>
          <Schema name="S" id="S"><SimpleField type="string" name="a"><displayName>Pretty</displayName></SimpleField></Schema>
          <Placemark><name>P</name><ExtendedData><SchemaData schemaUrl="#S"><SimpleData name="a">v</SimpleData></SchemaData></ExtendedData></Placemark>
        </Document></kml>
        """
        let pm = try #require(KMLParser.parse(data: Data(xml.utf8)).root.allPlacemarks.first)
        #expect(pm.extendedData == [KMLDataItem(name: "a", value: "v")])
    }

    @Test func duplicateDataNamesGetDistinctIds() throws {
        let pm = try onlyPlacemark("""
        <ExtendedData>
          <Data name="tag"><value>a</value></Data>
          <Data name="tag"><value>b</value></Data>
          <Data name="tag"><value>c</value></Data>
        </ExtendedData>
        """)
        #expect(pm.extendedData.map(\.value) == ["a", "b", "c"])
        #expect(Set(pm.extendedData.map(\.id)).count == 3)
        #expect(pm.extendedData.map(\.name) == ["tag", "tag", "tag"])
    }

    @Test func duplicateSimpleDataNamesGetDistinctIds() throws {
        let pm = try onlyPlacemark("""
        <ExtendedData><SchemaData schemaUrl="#S">
          <SimpleData name="x">1</SimpleData><SimpleData name="x">2</SimpleData>
        </SchemaData></ExtendedData>
        """)
        #expect(pm.extendedData.map(\.value) == ["1", "2"])
        #expect(Set(pm.extendedData.map(\.id)).count == 2)
    }

    @Test func dataItemDefaultsKeepExistingCallersCompiling() {
        let item = KMLDataItem(name: "n", value: "v")
        #expect(item.id == "n")
        #expect(item.displayName == nil)
    }
}
