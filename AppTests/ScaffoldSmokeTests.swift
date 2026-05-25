import Testing
import Foundation
@testable import Pinfold

/// Baseline test proving the app target + test bundle compile and link, and that the
/// PinfoldCore dependency is reachable from the app module. Real service tests land in
/// later chunks.
@Suite struct ScaffoldSmokeTests {
    @Test func appGroupIdentifierIsDefined() {
        #expect(AppGroup.identifier == "group.tech.inkhorn.pinfold")
    }
}
