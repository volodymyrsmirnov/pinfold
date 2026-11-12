import Foundation
import Observation

/// Whether iCloud sync is doing what the user asked, shared through the environment so the
/// catalogue banner and the Settings status line agree.
@MainActor @Observable final class SyncStatus {
    /// The resolved sync state.
    enum State: Equatable {
        /// Sync is switched off; files live on this device.
        case off
        /// Sync is on and the iCloud container is the active root.
        case active
        /// Sync is on but iCloud cannot be reached (signed out, restricted, still starting).
        /// The app keeps working on the local root until it returns.
        case unavailable
    }

    /// The last resolved state. Starts at `.off` until `RootView` resolves the real root.
    var state: State = .off

    /// `false` until the first real resolution, so launch is told apart from a re-resolve.
    var hasResolved = false

    /// The iCloud identity the state was resolved under, so an account switch is noticed even
    /// when the state itself did not change.
    var identityToken: Data?

    /// `true` while sync is on but iCloud cannot be reached.
    var isUnavailable: Bool {
        state == .unavailable
    }
}
