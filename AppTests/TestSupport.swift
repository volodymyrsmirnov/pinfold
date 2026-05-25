import Foundation
@testable import Pinfold

// MARK: - Fixture loader

/// Marker class used to locate the test bundle at runtime.
final class _TestBundleMarker {}

/// Loads test fixture files from the `Fixtures/` folder copied into the test bundle.
enum AppFixture {
    /// Loads the raw bytes for a fixture by filename (e.g. `"Rome.kml"`, `"Rome.kmz"`).
    ///
    /// XcodeGen flattens non-code resources into the bundle root by default, so the file
    /// can be found either at the bare filename or under a `Fixtures/` subpath.
    static func data(_ name: String) throws -> Data {
        let bundle = Bundle(for: _TestBundleMarker.self)
        guard let url = bundle.url(forResource: name, withExtension: nil) ??
                        bundle.url(forResource: "Fixtures/\(name)", withExtension: nil) else {
            throw NSError(domain: "AppFixture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Fixture not found: \(name)"])
        }
        return try Data(contentsOf: url)
    }
}
