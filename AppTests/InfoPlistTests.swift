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
}
