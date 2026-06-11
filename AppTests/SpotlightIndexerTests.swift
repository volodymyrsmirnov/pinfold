import CoreSpotlight
import Foundation
@testable import Pinfold
import PinfoldCore
import Testing

/// Tests for `SpotlightIndexer`'s pure surface: the `SpotlightID` identifier scheme and the
/// `CSSearchableItem` builder. The fire-and-forget wrapper over the live `CSSearchableIndex`
/// is not unit-tested (the builder is the tested surface; the wrapper is a thin shell).
struct SpotlightIndexerTests {
    // MARK: - Fixtures

    private func makeEntry(
        folderName: String = "11111111-1111-1111-1111-111111111111",
        displayName: String = "Rome Trip",
        pointCount: Int = 3
    ) -> CatalogEntry {
        CatalogEntry(
            id: UUID(uuidString: folderName) ?? UUID(),
            displayName: displayName,
            sourceFilename: "rome.kml",
            importDate: .now,
            pointCount: pointCount,
            contentSHA256: "abc",
            storageFolderName: folderName,
            trashedAt: nil
        )
    }

    // MARK: - SpotlightID round-trip

    @Test func entryIDIsBareFolderName() {
        let raw = SpotlightID.entry(folderName: "FOLDER")
        #expect(raw == "FOLDER")
        let parsed = SpotlightID.parse(raw)
        #expect(parsed?.folderName == "FOLDER")
        #expect(parsed?.placemarkKey == nil)
    }

    @Test func placemarkIDRoundTrips() {
        let raw = SpotlightID.placemark(folderName: "FOLDER", placemarkKey: "h:abcdef")
        #expect(raw == "FOLDER/h:abcdef")
        let parsed = SpotlightID.parse(raw)
        #expect(parsed?.folderName == "FOLDER")
        #expect(parsed?.placemarkKey == "h:abcdef")
    }

    /// stableKeys can be `"id:<sourceID>"` with an author-supplied sourceID that itself
    /// contains "/". Parsing must split on the FIRST "/" only so the key survives intact.
    @Test func placemarkIDPreservesSlashesInStableKey() {
        let key = "id:a/b/c"
        let raw = SpotlightID.placemark(folderName: "FOLDER", placemarkKey: key)
        #expect(raw == "FOLDER/id:a/b/c")
        let parsed = SpotlightID.parse(raw)
        #expect(parsed?.folderName == "FOLDER")
        #expect(parsed?.placemarkKey == key)
    }

    @Test func parseRejectsEmpty() {
        #expect(SpotlightID.parse("") == nil)
    }

    /// A leading "/" means an empty folder name — unambiguously invalid (folder names are
    /// UUID strings, which never start with "/").
    @Test func parseRejectsEmptyFolderName() {
        #expect(SpotlightID.parse("/x") == nil)
        #expect(SpotlightID.parse("/") == nil)
    }

    /// A trailing "/" with no key is a placemark id with an empty key — also invalid.
    @Test func parseRejectsEmptyPlacemarkKey() {
        #expect(SpotlightID.parse("FOLDER/") == nil)
    }

    // MARK: - items(for:indexEntries:)

    @Test func itemsCountIsNonEmptyNamedPlacemarksPlusEntry() {
        let entry = makeEntry()
        let indexEntries = [
            PlacemarkIndex.Entry(key: "h:1", name: "Colosseum", lat: 41.89, lon: 12.49),
            PlacemarkIndex.Entry(key: "h:2", name: "", lat: 41.9, lon: 12.5), // nameless: skipped
            PlacemarkIndex.Entry(key: "h:3", name: "Pantheon", lat: nil, lon: nil),
        ]
        let items = SpotlightIndexer.items(for: entry, indexEntries: indexEntries)
        // 2 named placemarks + 1 entry item.
        #expect(items.count == 3)
    }

    @Test func entryItemHasEntryDomainAndDisplayName() {
        let entry = makeEntry(displayName: "Rome Trip")
        let items = SpotlightIndexer.items(for: entry, indexEntries: [])
        // No placemarks → just the entry item.
        #expect(items.count == 1)
        let entryItem = try? #require(items.first)
        #expect(entryItem?.domainIdentifier == "entries")
        #expect(entryItem?.uniqueIdentifier == "11111111-1111-1111-1111-111111111111")
        #expect(entryItem?.attributeSet.title == "Rome Trip")
    }

    @Test func placemarkItemCarriesTitleCoordsDomainAndEntryName() {
        let entry = makeEntry(folderName: "FOLDER", displayName: "Rome Trip")
        let indexEntries = [
            PlacemarkIndex.Entry(key: "h:1", name: "Colosseum", lat: 41.89, lon: 12.49),
        ]
        let items = SpotlightIndexer.items(for: entry, indexEntries: indexEntries)
        let placemarkItem = try? #require(items.first { $0.domainIdentifier == "placemarks" })
        #expect(placemarkItem?.uniqueIdentifier == "FOLDER/h:1")
        #expect(placemarkItem?.attributeSet.title == "Colosseum")
        #expect(placemarkItem?.attributeSet.contentDescription == "Rome Trip")
        #expect(placemarkItem?.attributeSet.latitude == 41.89)
        #expect(placemarkItem?.attributeSet.longitude == 12.49)
        #expect(placemarkItem?.attributeSet.supportsNavigation == 1)
    }

    @Test func placemarkItemWithoutCoordsHasNoLatLon() {
        let entry = makeEntry(folderName: "FOLDER")
        let indexEntries = [
            PlacemarkIndex.Entry(key: "h:9", name: "Pantheon", lat: nil, lon: nil),
        ]
        let items = SpotlightIndexer.items(for: entry, indexEntries: indexEntries)
        let placemarkItem = try? #require(items.first { $0.domainIdentifier == "placemarks" })
        #expect(placemarkItem?.attributeSet.latitude == nil)
        #expect(placemarkItem?.attributeSet.longitude == nil)
    }
}
