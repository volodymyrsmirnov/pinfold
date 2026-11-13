import Foundation
@testable import Pinfold
import PinfoldCore
import Testing

/// `NetworkLinkOffer`: what the file screen's Subscribe card is built from. Building an offer
/// never touches the network.
struct NetworkLinkOfferTests {
    private static func document(links: [String], placemarks: Int) throws -> KMLDocument {
        let linkXML = links.enumerated().map { index, href in
            "<NetworkLink><name>L\(index)</name><Link><href>\(href)</href></Link></NetworkLink>"
        }.joined()
        let placemarkXML = (0 ..< placemarks).map { index in
            "<Placemark><name>P\(index)</name><Point><coordinates>1,2,0</coordinates></Point></Placemark>"
        }.joined()
        let data = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2"><Document><name>Doc</name>\(linkXML)\(placemarkXML)</Document></kml>
        """.utf8)
        return try KMLReader.readDocument(data: data)
    }

    @Test func offer_mixedDocument_isOffered_notReplacing() throws {
        let document = try Self.document(links: ["https://one.test/a.kml"], placemarks: 2)
        let offer = try #require(NetworkLinkOffer(document: document))
        #expect(offer.isSingle)
        #expect(offer.placemarkCount == 2)
        #expect(!offer.replacesThisList)
    }

    @Test func offer_singleLinkOnly_replaces() throws {
        let document = try Self.document(links: ["http://one.test/a.kml", "ftp://x.test/y"], placemarks: 0)
        let offer = try #require(NetworkLinkOffer(document: document))
        #expect(offer.links.count == 1)
        #expect(offer.hosts == ["one.test"])
        #expect(offer.replacesThisList)
    }

    @Test func offer_severalLinksOnly_doesNotReplace() throws {
        let document = try Self.document(links: ["https://one.test/a.kml", "https://two.test/b.kml"], placemarks: 0)
        let offer = try #require(NetworkLinkOffer(document: document))
        #expect(offer.links.count == 2)
        #expect(!offer.replacesThisList)
    }

    @Test func offer_noFetchableLinks_isNil() throws {
        let document = try Self.document(links: ["ftp://x.test/y", "file:///etc/passwd"], placemarks: 3)
        #expect(NetworkLinkOffer(document: document) == nil)
        let plain = try Self.document(links: [], placemarks: 1)
        #expect(NetworkLinkOffer(document: plain) == nil)
    }

    // MARK: - Card button (F12, F7)

    @Test func buttonTitle_followsWhatSubscribingDoes() throws {
        let replacing = try #require(NetworkLinkOffer(document: Self.document(links: ["https://one.test/a.kml"],
                                                                              placemarks: 0)))
        #expect(replacing.buttonTitle == "Subscribe")
        let mixed = try #require(NetworkLinkOffer(document: Self.document(links: ["https://one.test/a.kml"],
                                                                          placemarks: 2)))
        #expect(mixed.buttonTitle == "Subscribe to 1 List")
        let several = try #require(NetworkLinkOffer(document: Self.document(
            links: ["https://one.test/a.kml", "https://two.test/b.kml"], placemarks: 0
        )))
        #expect(several.buttonTitle == "Subscribe to 2 Lists")
    }

    @Test func button_isHiddenWhileSubscribingAndOnceFinished() {
        #expect(NetworkLinkPrompt.showsButton(for: .idle))
        #expect(NetworkLinkPrompt.showsButton(for: .failed("x")))
        #expect(!NetworkLinkPrompt.showsButton(for: .subscribing))
        #expect(!NetworkLinkPrompt.showsButton(for: .finished("Added 2 lists.")))
    }

    // MARK: - Status after subscribing each link (G11)

    @Test func eachLink_allAdded_finishes() {
        #expect(NetworkLinkStatus.afterSubscribingEach(added: 1, failed: 0, firstError: nil) == .finished("Added 1 list."))
        #expect(NetworkLinkStatus.afterSubscribingEach(added: 3, failed: 0, firstError: nil) == .finished("Added 3 lists."))
    }

    /// Some links failed: say so and keep the button, so the person can retry (links already
    /// added come back as existing lists and aren't added twice).
    @Test func eachLink_partialFailure_showsTheErrorAndKeepsTheButton() {
        let status = NetworkLinkStatus.afterSubscribingEach(added: 2, failed: 1, firstError: "HTTP 404")
        #expect(status == .partial("Added 2 lists. 1 couldn't be added: HTTP 404"))
        #expect(NetworkLinkPrompt.showsButton(for: .partial("x")))
        #expect(NetworkLinkStatus.afterSubscribingEach(added: 1, failed: 2, firstError: "Boom")
            == .partial("Added 1 list. 2 couldn't be added: Boom"))
    }

    @Test func eachLink_addedWithSomeAlreadyFollowed_saysSo() {
        let one = NetworkLinkStatus.afterSubscribingEach(added: 1, failed: 0, firstError: nil, existing: 1)
        #expect(one == .finished("Added 1 list. 1 was already in your lists."))
        let many = NetworkLinkStatus.afterSubscribingEach(added: 1, failed: 0, firstError: nil, existing: 2)
        #expect(many == .finished("Added 1 list. 2 were already in your lists."))
    }

    @Test func eachLink_nothingAdded_failsOrDefersToTheCaller() {
        #expect(NetworkLinkStatus.afterSubscribingEach(added: 0, failed: 2, firstError: "Boom") == .failed("Boom"))
        #expect(NetworkLinkStatus.afterSubscribingEach(added: 0, failed: 0, firstError: nil) == nil)
    }

    // MARK: - Single link already being added (G8)

    /// The other subscribe may still fail: the button stays so the person can retry (a retry
    /// finds the list being added, or the one it made).
    @Test func singleLink_alreadyBeingAdded_saysSoAndKeepsTheButton() {
        #expect(NetworkLinkStatus.alreadyBeingAdded == .pending("This list is already being added."))
        #expect(NetworkLinkPrompt.showsButton(for: .alreadyBeingAdded))
    }
}
