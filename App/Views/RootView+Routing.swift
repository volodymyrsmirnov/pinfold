import CoreSpotlight
import os
import SwiftUI

extension RootView {
    // MARK: - Deep-link routing (App Intents + Spotlight)

    /// Selects the active entry with `folderName`, or logs and no-ops when it's missing/trashed.
    func openEntry(folderName: String) {
        guard let entry = catalog.active.first(where: { $0.storageFolderName == folderName }) else {
            if !didBootstrap {
                pendingColdLaunchTarget = (folderName, nil)
            } else {
                Self.routingLogger.info(
                    "Deep link to missing/trashed entry '\(folderName, privacy: .public)' — ignored."
                )
            }
            return
        }
        pendingPlacemarkKey = nil
        pendingRestore = nil
        selectedEntryID = entry.id
    }

    /// Handles a Core Spotlight result tap. The identifier is the tapped item's `SpotlightID`:
    /// an entry item selects its file; a placemark item selects the file AND deep-links directly
    /// to the placemark by passing its stableKey as `pendingPlacemarkKey`.
    func handleSpotlightActivity(_ activity: NSUserActivity) {
        guard let raw = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              let parsed = SpotlightID.parse(raw)
        else { return }

        guard let entry = catalog.active.first(where: { $0.storageFolderName == parsed.folderName }) else {
            if !didBootstrap {
                pendingColdLaunchTarget = (parsed.folderName, parsed.placemarkKey)
            } else {
                Self.routingLogger.info(
                    "Spotlight tap on missing/trashed entry '\(parsed.folderName, privacy: .public)' — ignored."
                )
            }
            return
        }

        // A placemark item carries its stableKey directly in the Spotlight identifier — pass it
        // straight through as the deep-link target (no name lookup needed). An entry item has no
        // placemark key, so the file just opens.
        pendingPlacemarkKey = parsed.placemarkKey
        pendingRestore = nil
        selectedEntryID = entry.id
    }
}
