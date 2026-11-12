@testable import Pinfold
import Testing

@MainActor struct NetworkStatusTests {
    @Test func unsatisfiedPath_isOffline() {
        #expect(NetworkStatus(pathStatus: .unsatisfied).isOnline == false)
        #expect(NetworkStatus(pathStatus: .requiresConnection).isOnline == false)
        #expect(NetworkStatus(isOnline: false).isOnline == false)
    }

    @Test func satisfiedPath_isOnline() {
        #expect(NetworkStatus(pathStatus: .satisfied).isOnline == true)
        #expect(NetworkStatus(isOnline: true).isOnline == true)
    }
}
