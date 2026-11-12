import Foundation
@testable import Pinfold
import Testing

/// Checks on the app's `Info.plist`. Reads the source file next to the repo (via `#filePath`)
/// rather than `Bundle.main`, so the tests don't depend on how the test host is wired.
struct InfoPlistTests {
    private static func appInfoPlist() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // AppTests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("App/Info.plist")
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(plist as? [String: Any])
    }

    @Test func documentTypesUseAlternateRank() throws {
        let plist = try Self.appInfoPlist()
        let types = try #require(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        #expect(!types.isEmpty)
        for type in types {
            #expect(type["LSHandlerRank"] as? String == "Alternate")
        }
    }

    @Test func everyRosterSchemeIsDeclaredInQueriesSchemes() throws {
        let plist = try Self.appInfoPlist()
        let declared = try Set(#require(plist["LSApplicationQueriesSchemes"] as? [String]))
        let needed = Set(MapApp.roster.compactMap(\.urlScheme))
        #expect(needed.subtracting(declared).isEmpty, "missing: \(needed.subtracting(declared))")
    }

    @Test func documentTypesCoverAllImportFormats() throws {
        let plist = try Self.appInfoPlist()
        let types = try #require(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        let claimed = Set(types.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] })
        #expect(claimed.isSuperset(of: [
            "com.google.earth.kml", "com.google.earth.kmz", "com.topografix.gpx", "public.geojson",
        ]))
        #expect(!claimed.contains("public.json"), "plain JSON is only offered in the in-app picker")
        let imported = plist["UTImportedTypeDeclarations"] as? [[String: Any]] ?? []
        let gpx = imported.first { $0["UTTypeIdentifier"] as? String == "com.topografix.gpx" }
        #expect(gpx?["UTTypeConformsTo"] as? [String] == ["public.xml"])
    }

    @Test func shareExtensionRuleCoversGPXAndGeoJSONButNotPlainJSON() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ShareExtension/Info.plist")
        let plist = try #require(
            PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any]
        )
        let ext = try #require(plist["NSExtension"] as? [String: Any])
        let attrs = try #require(ext["NSExtensionAttributes"] as? [String: Any])
        let rule = try #require(attrs["NSExtensionActivationRule"] as? String)
        for id in ["com.google.earth.kml", "com.google.earth.kmz", "com.topografix.gpx", "public.geojson"] {
            #expect(rule.contains("\"\(id)\""))
        }
        #expect(!rule.contains("\"public.json\""))
    }
}
