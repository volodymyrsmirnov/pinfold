import Foundation

enum FixtureError: Error {
    case missing(String)
}

enum Fixture {
    static func data(_ name: String) throws -> Data {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
        guard let url else { throw FixtureError.missing(name) }
        return try Data(contentsOf: url)
    }
}
