import Foundation

// MARK: - EntryRoute

/// A screen reachable inside an open file, as a self-contained durable value — the unit of
/// the detail column's `NavigationStack(path:)`.
///
/// Routes carry placemark `stableKey`s (the same durable identifier Spotlight, favorites,
/// and App Intents use), never live `KMLPlacemark`s, so a persisted route resolves — or
/// silently fails — against a re-parsed document exactly like existing deep links.
enum EntryRoute: Hashable, Codable {
    /// The placemark (POI) page.
    case placemark(stableKey: String)
    /// The full-file map. `focusKey` non-nil = "Show on Map" from a POI page (open zoomed
    /// to that pin); nil = the list's toolbar map button (fit-all / saved camera).
    case map(focusKey: String?)
}

extension EntryRoute {
    /// Envelope for the persisted route array. The version tag lets a future app change the
    /// route schema and have old payloads silently discarded instead of half-decoded.
    private struct ResumeEnvelope: Codable {
        static let currentVersion = 1
        var version: Int
        var routes: [EntryRoute]
    }

    /// Encodes routes for UserDefaults persistence. `nil` only on encoder failure
    /// (practically unreachable for this payload).
    static func encodeForResume(_ routes: [EntryRoute]) -> Data? {
        try? JSONEncoder().encode(ResumeEnvelope(version: ResumeEnvelope.currentVersion, routes: routes))
    }

    /// Decodes a persisted route array. Anything invalid — nil, corrupt bytes, or a foreign
    /// version — yields `[]`: the restored file then opens at its placemark list (spec's
    /// failure table), never a half-restored stack.
    static func decodeForResume(_ data: Data?) -> [EntryRoute] {
        guard let data,
              let envelope = try? JSONDecoder().decode(ResumeEnvelope.self, from: data),
              envelope.version == ResumeEnvelope.currentVersion
        else { return [] }
        return envelope.routes
    }

    /// Validates persisted routes against the freshly parsed document, keeping the longest
    /// valid prefix (a stack must not contain a hole). `resolves` reports whether a
    /// placemark `stableKey` still exists in the document.
    ///
    /// A restored `.map` route drops its `focusKey`: the saved per-file camera already
    /// encodes where the user actually was and must win over a re-focus zoom. (The pin's
    /// selection preview card is consequently not restored — accepted in the spec.)
    static func validatedForRestore(
        _ routes: [EntryRoute], resolves: (String) -> Bool
    ) -> [EntryRoute] {
        var valid: [EntryRoute] = []
        for route in routes {
            switch route {
            case let .placemark(stableKey):
                guard resolves(stableKey) else { return valid }
                valid.append(route)
            case .map:
                valid.append(.map(focusKey: nil))
            }
        }
        return valid
    }
}

// MARK: - RestoreBundle

/// A one-shot navigation payload handed to `KMLDetailView` when a selection is driven
/// programmatically — by a deep link (Spotlight, App Intent, a "Places"/favorites hit) or
/// by session restore. Consumed once via `onConsumeRestore`, like the `initialPlacemarkKey`
/// mechanism it replaces.
///
/// `entryFolderName` distinguishes the two producers: non-nil marks a session-restore
/// bundle (routes AND the transient list state are applied, and `RootView` only hands it to
/// the matching entry); nil marks a deep-link bundle (routes only — a live deep link must
/// never clobber the open file's search/sort/collapse state).
struct RestoreBundle: Equatable {
    var entryFolderName: String?
    var routes: [EntryRoute] = []
    var searchText: String = ""
    var collapsedFolderIDs: Set<String> = []
    var nearestFirst: Bool = false
    var scrollAnchorRowID: String?
}
