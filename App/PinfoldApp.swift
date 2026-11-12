import SwiftUI

@main
struct PinfoldApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        // Menu commands read each window's focused-scene values (see `AppCommands`), so they
        // act on the focused window only.
        .commands {
            AppCommands()
        }
    }
}
