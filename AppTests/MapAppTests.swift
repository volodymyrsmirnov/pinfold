import Foundation
@testable import Pinfold
import Testing

// MARK: - Coordinate fixture

private let lat = 41.8902
private let lng = 12.4922
private let name = "Colosseo, Roma"

// MARK: - MapAppTests

/// Tests for `MapApp` URL construction and `MapAppService` detection / launch logic.
///
/// No SwiftData, no UIApplication — `MapAppService` is always constructed with injected
/// stubs so tests run without a simulator process and without real scheme checks.
///
/// URL construction is tested with exact-equality assertions for all apps except Apple
/// Maps (which uses `contains` as specified). The expected strings were derived by
/// running the builders against the coordinate fixture and printing `absoluteString`.
@MainActor struct MapAppTests {
    // MARK: - URL construction: Apple Maps

    // The task specifies `contains` checks for Apple Maps (scheme + coordinates + encoded name).

    @Test func appleURL_containsCoordinates() throws {
        let url = try #require(MapApp.apple.makeURL(lat, lng, name))
        #expect(url.absoluteString.contains("ll=41.8902,12.4922"))
    }

    @Test func appleURL_containsEncodedName() throws {
        let url = try #require(MapApp.apple.makeURL(lat, lng, name))
        let str = url.absoluteString
        // URLComponents percent-encodes the space in "Colosseo, Roma" to %20;
        // the comma survives as-is under .urlQueryAllowed.
        #expect(str.contains("q=Colosseo,%20Roma"))
    }

    @Test func appleURL_schemeIsHttps() throws {
        let url = try #require(MapApp.apple.makeURL(lat, lng, name))
        #expect(url.scheme == "https")
        #expect(url.host == "maps.apple.com")
    }

    // MARK: - URL construction: Google Maps (exact)

    @Test func googleURL_exact() throws {
        let url = try #require(MapApp.google.makeURL(lat, lng, name))
        // URLComponents places the `?` after `://` for an authority-less URL.
        // Commas in query values survive as-is under .urlQueryAllowed.
        #expect(url.absoluteString == "comgooglemaps://?q=41.8902,12.4922&center=41.8902,12.4922")
    }

    @Test func googleWebURL_exact() throws {
        let url = try #require(MapApp.googleWeb.makeURL(lat, lng, name))
        #expect(url.absoluteString == "https://www.google.com/maps/search/?api=1&query=41.8902,12.4922")
    }

    // MARK: - URL construction: Waze (exact)

    @Test func wazeURL_exact() throws {
        let url = try #require(MapApp.waze.makeURL(lat, lng, name))
        #expect(url.absoluteString == "waze://?ll=41.8902,12.4922&navigate=yes")
    }

    // MARK: - URL construction: Organic Maps (exact)

    @Test func organicURL_exact() throws {
        let url = try #require(MapApp.organic.makeURL(lat, lng, name))
        // Space in name is percent-encoded to %20; comma survives.
        #expect(url.absoluteString == "om://map?v=1&ll=41.8902,12.4922&n=Colosseo,%20Roma")
    }

    // MARK: - URL construction: Maps.me (exact)

    @Test func mapsMeURL_exact() throws {
        let url = try #require(MapApp.mapsme.makeURL(lat, lng, name))
        #expect(url.absoluteString == "mapsme://map?ll=41.8902,12.4922&n=Colosseo,%20Roma")
    }

    // MARK: - URL construction: OsmAnd (exact)

    @Test func osmandURL_exact() throws {
        let url = try #require(MapApp.osmand.makeURL(lat, lng, name))
        #expect(url.absoluteString == "osmandmaps://?lat=41.8902&lon=12.4922&z=16")
    }

    // MARK: - URL construction: Magic Earth (exact)

    @Test func magicEarthURL_exact() throws {
        let url = try #require(MapApp.magicearth.makeURL(lat, lng, name))
        // URLQueryItem(name: "drive_to", value: nil) serialises as just `drive_to` (no `=`).
        #expect(url.absoluteString == "magicearth://?drive_to&lat=41.8902&lon=12.4922&name=Colosseo,%20Roma")
    }

    // MARK: - URL construction: Citymapper (exact)

    @Test func citymapperURL_exact() throws {
        let url = try #require(MapApp.citymapper.makeURL(lat, lng, name))
        #expect(url.absoluteString == "citymapper://directions?endcoord=41.8902,12.4922&endname=Colosseo,%20Roma")
    }

    // MARK: - URL construction: Yandex Maps (exact; pt is lng,lat)

    @Test func yandexURL_lngLatOrdering() throws {
        let url = try #require(MapApp.yandex.makeURL(lat, lng, name))
        // pt parameter must be lng,lat — 12.4922 before 41.8902.
        #expect(url.absoluteString == "yandexmaps://maps.yandex.ru/?pt=12.4922,41.8902&z=16")
    }

    // MARK: - URL construction: 2GIS (exact; path is lng,lat)

    @Test func twoGISURL_lngLatOrdering() throws {
        let url = try #require(MapApp.twogis.makeURL(lat, lng, name))
        // Path must be lng,lat — 12.4922 before 41.8902.
        #expect(url.absoluteString == "dgis://2gis.ru/geo/12.4922,41.8902")
    }

    // MARK: - URL construction: Sygic (exact; path is lng,lat, pipes encoded as %7C)

    @Test func sygicURL_lngLatOrdering() throws {
        let url = try #require(MapApp.sygic.makeURL(lat, lng, name))
        // Pipe `|` chars are pre-encoded to `%7C` so URL(string:) accepts the literal.
        // Coordinate order is lng,lat (12.4922 before 41.8902).
        #expect(url.absoluteString == "com.sygic.aura://coordinate%7C12.4922%7C41.8902%7Cshow")
    }

    // MARK: - URL construction: Guru Maps (exact; no label, lat,lng order)

    @Test func guruURL_exact() throws {
        let url = try #require(MapApp.guru.makeURL(lat, lng, name))
        // The guru://show endpoint has no name parameter, so the name is dropped.
        #expect(url.absoluteString == "guru://show?place=41.8902,12.4922")
    }

    // MARK: - MapAppService.installedApps

    @Test func installedApps_alwaysIncludesApple() {
        let service = MapAppService(canOpen: { _ in false })
        let installed = service.installedApps()
        #expect(installed.contains { $0.id == "apple" })
    }

    @Test func installedApps_withGoogleSchemeTrueOnly_returnsExactlyAppleAndGoogle() {
        let service = MapAppService(
            canOpen: { url in url.scheme == "comgooglemaps" }
        )
        let installed = service.installedApps()
        // Must be exactly [apple, google] in roster order.
        #expect(installed.map(\.id) == ["apple", "google"])
    }

    @Test func installedApps_preservesRosterOrder() {
        let service = MapAppService(canOpen: { _ in true })
        let installed = service.installedApps()
        let rosterIDs = MapApp.roster.map(\.id)
        let installedIDs = installed.map(\.id)
        #expect(installedIDs == rosterIDs,
                "installedApps() must preserve roster order when all apps are installed")
    }

    @Test func platformRoster_whenRunningOniOSAppOnMac_addsGoogleWebAfterApple() {
        let ids = MapApp.platformRoster(isiOSAppOnMac: true).map(\.id)
        #expect(ids.prefix(3) == ["apple", "google-web", "google"])
    }

    @Test func platformRoster_whenNotRunningOniOSAppOnMac_matchesiOSRoster() {
        let ids = MapApp.platformRoster(isiOSAppOnMac: false).map(\.id)
        #expect(ids == MapApp.roster.map(\.id))
    }

    @Test func installedApps_onMacAlwaysIncludesAppleAndGoogleWeb() {
        let service = MapAppService(
            roster: MapApp.platformRoster(isiOSAppOnMac: true),
            canOpen: { _ in false }
        )
        let installed = service.installedApps()
        #expect(installed.map(\.id) == ["apple", "google-web"])
    }

    // MARK: - MapAppService.availableApps

    @Test func availableApps_emptyEnabledIDs_returnsAllInstalled() {
        let service = MapAppService(canOpen: { url in url.scheme == "comgooglemaps" })
        let available = service.availableApps(enabledIDs: [])
        let installed = service.installedApps()
        #expect(available.map(\.id) == installed.map(\.id),
                "Empty enabledIDs must return all installed apps")
    }

    @Test func availableApps_filtersByEnabledSet() {
        let service = MapAppService(canOpen: { _ in true })
        let available = service.availableApps(enabledIDs: ["apple", "waze"])
        let ids = available.map(\.id)
        #expect(ids == ["apple", "waze"],
                "availableApps must return only enabled+installed apps in roster order")
    }

    @Test func availableApps_enabledSetWithUninstalledApp_isIgnored() {
        // canOpen returns false for everything (google not installed)
        let service = MapAppService(canOpen: { _ in false })
        // Request google (not installed) and apple (always available)
        let available = service.availableApps(enabledIDs: ["apple", "google"])
        #expect(available.map(\.id) == ["apple"],
                "google is not installed; only apple must appear in availableApps")
    }

    // MARK: - MapAppService.open

    @Test func open_callsOpenerWithBuiltURL() throws {
        let collector = URLCollector()
        let service = MapAppService(
            canOpen: { _ in true },
            opener: { collector.urls.append($0) }
        )
        let result = service.open(MapApp.apple, latitude: lat, longitude: lng, name: name)
        #expect(result == true)
        #expect(collector.urls.count == 1)
        let opened = try #require(collector.urls.first)
        // Apple Maps URL must contain the coordinate in ll= parameter
        #expect(opened.absoluteString.contains("ll=41.8902,12.4922"))
    }

    @Test func open_returnsFalseWhenURLIsNil() {
        let collector = URLCollector()
        let service = MapAppService(canOpen: { _ in true }, opener: { collector.urls.append($0) })

        // A degenerate app whose builder always returns nil
        let broken = MapApp(
            id: "broken",
            displayName: "Broken",
            urlScheme: "broken",
            alwaysAvailable: false,
            makeURL: { _, _, _ in nil }
        )
        let result = service.open(broken, latitude: lat, longitude: lng, name: name)
        #expect(result == false)
        #expect(collector.urls.isEmpty)
    }

    // MARK: - MapAppService.resolveDefault

    @Test func resolveDefault_returnsAppWhenSetInstalledAndEnabled() {
        let service = MapAppService(canOpen: { url in url.scheme == "comgooglemaps" })
        let resolved = service.resolveDefault(id: "google", enabledIDs: ["google"])
        #expect(resolved?.id == "google")
    }

    @Test func resolveDefault_returnsNilWhenDefaultIDIsNil() {
        let service = MapAppService(canOpen: { _ in true })
        let resolved = service.resolveDefault(id: nil, enabledIDs: [])
        #expect(resolved == nil)
    }

    @Test func resolveDefault_returnsNilWhenAppNotInstalled() {
        // canOpen returns false for everything — simulates an uninstalled default
        let service = MapAppService(canOpen: { _ in false })
        let resolved = service.resolveDefault(id: "google", enabledIDs: ["google"])
        #expect(resolved == nil,
                "resolveDefault must return nil when the default app is not installed")
    }

    @Test func resolveDefault_returnsNilWhenAppNotEnabled() {
        // google is installed but NOT in enabledIDs
        let service = MapAppService(canOpen: { url in url.scheme == "comgooglemaps" })
        let resolved = service.resolveDefault(id: "google", enabledIDs: ["apple"])
        #expect(resolved == nil,
                "resolveDefault must return nil when the default app is installed but not enabled")
    }

    @Test func resolveDefault_withEmptyEnabledIDs_andInstalledApp_returnsApp() {
        // Empty enabledIDs means all installed are enabled; apple is always available
        let service = MapAppService(canOpen: { _ in false })
        let resolved = service.resolveDefault(id: "apple", enabledIDs: [])
        #expect(resolved?.id == "apple",
                "Empty enabledIDs treats all installed as enabled; apple must resolve")
    }

    // MARK: - MapApp identity (Hashable / Equatable)

    @Test func mapApp_hashableByID() {
        let a = MapApp.apple
        let b = MapApp.apple
        #expect(a == b)
        var set = Set<MapApp>()
        set.insert(a)
        set.insert(b)
        #expect(set.count == 1)
    }

    @Test func mapApp_differentIDsAreNotEqual() {
        #expect(MapApp.apple != MapApp.google)
    }
}

// MARK: - Helpers

/// Reference-type URL collector for injecting into `MapAppService.opener` in tests.
private final class URLCollector: @unchecked Sendable {
    var urls: [URL] = []
}
