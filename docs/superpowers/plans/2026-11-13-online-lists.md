# Online Lists (Pinfold 2.1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Lists that follow a URL (KML, KMZ, GeoJSON, or a KML `<NetworkLink>`) and refresh themselves while Pinfold is open. Plus a native-looking Empty Trash control.

**Architecture:**
- **Subscription:** a `Subscription` value stored in `EntryMetadata` (`metadata.json`), with per-device refresh state in `resources/subscription-state.json`.
- **Refreshing:** a `@MainActor @Observable SubscriptionRefresher` decides what is due (a pure `SubscriptionSchedule`). It fetches with a conditional GET (`BoundedDownloader.fetchConditional`) and writes changed content through the crash-ordered snapshot writer. Unlike the 2.0 snapshot, it keeps the person's choices in `resources/`.
- **Subscribing:** new subscriptions go through `ImportCoordinator` with the duplicate prompt bypassed.

**Tech Stack:** Swift 6, SwiftUI (iOS 26), Swift Testing, PinfoldCore (Swift package), XcodeGen.

**Spec:** `docs/superpowers/specs/2026-11-13-online-lists-design.md` (read it first; this plan argues from it).

## Global Constraints

- Min iOS 26. No new third-party dependencies.
- Build/test only through `scripts/build.sh` and `scripts/test.sh [-only-testing:PinfoldTests/<Suite>]`. Parser: `cd PinfoldCore && swift test`.
- After adding files under `App/` or `AppTests/`, run `xcodegen generate` and commit `Pinfold.xcodeproj/project.pbxproj` with the source change. Never commit `xcuserdata`.
- `swiftlint lint` must stay at 0 errors. `swiftformat` owns comma and spacing style.
- Commits: `git -c commit.gpgsign=false commit …` (unattended run; never change git config).
- Keep `Task.detached` closures inside `nonisolated` free functions, and keep view `body`s small (see `FavoritesView.swift`).
- Tests inject `StorageLocations(root:)` under a temp dir and a stub downloader. Nothing touches the network or real storage. Suites sharing `@MainActor` state are `@Suite(.serialized)`.
- Default refresh interval **3600 s**. Polling floor **300 s**: `max(300, minRefreshPeriod)`. Download cap **50 MB**. Request timeout **30 s**.
- `http` is upgraded to `https` (`ResourceCache.httpsUpgraded`). Cross-host redirects are refused. Ephemeral session, no cookies.
- Copy fixed by the spec:
  - URL alert title `Subscribe to URL`; placeholder `https://example.com/map.kml`; message `Pinfold will check this address for updates while the app is open. The host can see your device's IP address.`; buttons `Cancel` / `Subscribe`.
  - Card: `This file links to online data. Subscribe to keep it updated from ⟨hosts⟩. Pinfold checks for changes while the app is open. The host can see this device's IP address.`; buttons `Subscribe` / `Subscribe to N Lists`.
  - Stop confirmation: `Stop updating "⟨name⟩"? The current copy stays as a normal list.`
  - Menu items: `Choose File…`, `Subscribe to URL…`, `Refresh Now`, `Copy URL`, `Stop Updating`.
  - Row text: `Updated ⟨relative⟩`, `Couldn't update`.
  - Accessibility labels: `Online list`, `Updating`, `Couldn't update`.
- A list's name is fixed at subscribe time. A refresh never changes `displayName`, `tags`, `favoriteKeys`, `visitedKeys`, `notes` or `trashedAt`.

## Review Focus

1. **A server that returns 200 with identical bytes every time** (no ETag support) must not rewrite the original or rebuild `resources/`. Test: `refresh_sameSHA_noWrite` (Task 6).
2. **A server returning HTML** (an error page or captive portal) with status 200 must leave the list intact and record an error. Test: `refresh_htmlBody_keepsContentAndRecordsError` (Task 6).
3. **A list that is trashed, restored, or has Stop Updating tapped while a fetch is in flight** must not resurrect the subscription or crash. Test: `refresh_stopUpdatingMidFlight_doesNotRestoreSubscription` (Task 6).
4. **Pasted URLs with surrounding whitespace, `HTTP://` uppercase, or a `webcal:`/`file:` scheme** must be normalised or rejected with a readable error. Test: `normalise_trimsAndUpgrades`, `normalise_rejectsNonHTTP` (Task 7).
5. **The app returning to the foreground repeatedly within seconds** must not stack fetches for the same list. Test: `refreshDue_twiceConcurrently_fetchesOnce` (Task 6).

---

### Task 1: Parse refresh hints in PinfoldCore

**Files:**
- Modify: `PinfoldCore/Sources/PinfoldCore/Model/KMLDocument.swift`
- Modify: `PinfoldCore/Sources/PinfoldCore/Parsing/KMLParserDelegate+NetworkLinks.swift`, `PinfoldCore/Sources/PinfoldCore/Parsing/KMLParserDelegate.swift`
- Test: `PinfoldCore/Tests/PinfoldCoreTests/NetworkLinkTests.swift`

**Interfaces:**
- Produces:
  - `public enum KMLRefreshMode: String, Sendable, Equatable, Codable { case onChange, onInterval, onExpire }`
  - `KMLNetworkLink` gains `public let refreshMode: KMLRefreshMode?` and `public let refreshInterval: TimeInterval?`. The init gains both parameters with defaults of `nil`, so existing call sites compile.
  - `public struct KMLNetworkLinkControl: Equatable, Sendable { public let minRefreshPeriod: TimeInterval?; public let expires: Date? }`
  - `KMLDocument.networkLinkControl: KMLNetworkLinkControl?` (init param, default `nil`).

- [ ] **Step 1: Write failing tests** in `NetworkLinkTests.swift`:
  - `refreshModeAndInterval_underLink`: `<Link><href>https://a/x.kml</href><refreshMode>onInterval</refreshMode><refreshInterval>600</refreshInterval></Link>` → `.onInterval`, `600`.
  - `refreshHints_underLegacyUrl`: the same under `<Url>`.
  - `unknownRefreshMode_isNil`: `<refreshMode>sometimes</refreshMode>` → `nil`. A non-numeric interval → `nil`.
  - `networkLinkControl_minRefreshAndExpires`: `<NetworkLinkControl><minRefreshPeriod>120</minRefreshPeriod><expires>2026-12-01T10:00:00Z</expires></NetworkLinkControl>` → `120` and that date.
  - `networkLinkControl_updateBlockIgnored`: a `<NetworkLinkControl>` containing `<Update><Change><Placemark targetId="a"><name>x</name></Placemark></Change></Update>` plus a top-level placemark → placemark count 1, and the name `x` appears nowhere.
  - `noNetworkLinkControl_isNil`.
- [ ] **Step 2:** `cd PinfoldCore && swift test --filter NetworkLinkTests` → FAIL (members missing).
- [ ] **Step 3:** Implement.
  - Capture `refreshMode` / `refreshInterval` only when their parent is `Link`/`Url` inside a `NetworkLink`, using the existing `elementStack`.
  - Capture `minRefreshPeriod` / `expires` only directly under `NetworkLinkControl`. Parse `expires` with `ISO8601DateFormatter` (`.withInternetDateTime`, then fall back to with fractional seconds).
  - Swallow everything inside `NetworkLinkControl > Update` the same way overlays are swallowed today. Placemarks inside it must not be added.
- [ ] **Step 4:** `swift test` (all) → PASS.
- [ ] **Step 5:** Commit: `feat(core): parse NetworkLink refresh hints and NetworkLinkControl`.

### Task 2: `Subscription` in `EntryMetadata` and `CatalogEntry`

**Files:**
- Create: `App/Model/Subscription.swift`
- Modify: `App/Model/EntryMetadata.swift`, `App/Model/CatalogEntry.swift`, `App/Services/ImportService.swift` (`ImportResult` + `commit`)
- Test: `AppTests/EntryMetadataTests.swift`, `AppTests/CatalogScannerTests.swift`

**Interfaces:**
- Consumes: `KMLRefreshMode` (Task 1).
- Produces:
  ```swift
  struct Subscription: Codable, Equatable, Sendable {
      enum Origin: String, Codable, Sendable { case url, networkLink }
      var url: URL                 // normalised https URL that is fetched
      var origin: Origin
      var subscribedAt: Date
      var refreshMode: KMLRefreshMode?
      var refreshInterval: TimeInterval?
  }
  ```
  - `EntryMetadata.subscription: Subscription?` and `CatalogEntry.subscription: Subscription?`, carried both ways by `CatalogEntry(metadata:storageFolderName:)` and `.metadata`.
  - `CatalogEntry.isOnline: Bool { subscription != nil }`.
  - `ImportResult.subscription: Subscription?`. It must be `var` or an init param defaulting to `nil`. `ImportService.commit` writes it into the new sidecar.

- [ ] **Step 1: Failing tests**:
  - `subscription_roundTrips` (encode → decode equal).
  - `legacySidecar_withoutSubscription_decodes`.
  - `nonSubscribedSidecar_hasNoSubscriptionKey`: the encoded JSON string does not contain `"subscription"`.
  - `merge_keepsCurrentSubscription`: current has A, the conflict has B → A. Current `nil`, conflict B → `nil`.
  - `scanner_populatesSubscription` in `CatalogScannerTests`.
  - `commit_writesSubscription` in `ImportServiceTests`.
- [ ] **Step 2:** `scripts/test.sh -only-testing:PinfoldTests/EntryMetadataTests` → FAIL.
- [ ] **Step 3:** Implement. Use `decodeIfPresent` and `encodeIfPresent`. Update `CodingKeys`, `init(from:)`, `encode(to:)` and the memberwise init, as the file's comment requires. `merging(conflicts:)` keeps `self.subscription`.
- [ ] **Step 4:** `xcodegen generate`, then run the three suites → PASS.
- [ ] **Step 5:** Commit: `feat: store list subscriptions in metadata.json`.

### Task 3: `SubscriptionSchedule` (pure due-date logic) and the local state file

**Files:**
- Create: `App/Services/SubscriptionSchedule.swift`, `App/Services/SubscriptionStateStore.swift`
- Test: `AppTests/SubscriptionScheduleTests.swift`, `AppTests/SubscriptionStateStoreTests.swift`

**Interfaces:**
- Consumes: `Subscription` (Task 2).
- Produces:
  ```swift
  struct SubscriptionState: Codable, Equatable, Sendable {
      var lastAttemptAt: Date?
      var lastSuccessAt: Date?
      var lastError: String?
      var etag: String?
      var lastModified: String?
      var serverMinRefreshPeriod: TimeInterval?
      var serverExpires: Date?    // NetworkLinkControl <expires>
      var httpExpires: Date?      // Cache-Control max-age or Expires header, resolved to a date
  }
  enum SubscriptionStateStore {
      static let filename = "subscription-state.json"
      static func read(in resourcesDir: URL) -> SubscriptionState      // missing/corrupt → SubscriptionState()
      static func write(_ state: SubscriptionState, in resourcesDir: URL) // atomic; creates dir
      static func remove(in resourcesDir: URL)
  }
  enum SubscriptionSchedule {
      static let defaultInterval: TimeInterval = 3600
      static let floor: TimeInterval = 300
      static func interval(for sub: Subscription, state: SubscriptionState, now: Date) -> TimeInterval
      static func nextDue(for sub: Subscription, state: SubscriptionState, now: Date) -> Date
      static func isDue(_ entry: CatalogEntry, state: SubscriptionState, now: Date) -> Bool
  }
  ```

- [ ] **Step 1: Failing table tests** (`SubscriptionScheduleTests`). All cases use `lastAttemptAt = t0`:
  - **Default interval:** `onInterval` 600 → due at `t0+600`. No mode → `t0+3600`. `onChange` → `t0+3600`.
  - **Floor:** `onInterval` 30 → `t0+300`. `serverMinRefreshPeriod` 900 with `onInterval` 600 → `t0+900`.
  - **`onExpire`:** with `serverExpires` `t0+7200` → `t0+7200`. With only `httpExpires` `t0+1800` → `t0+1800`. With neither → `t0+3600`. With `serverExpires` `t0+60` → floor `t0+300`.
  - **Failure:** `lastError` set → due at `t0+300`.
  - **Never attempted** → due now.
  - **Never due:** a trashed entry; a read-only entry (`sidecarState = .notDownloaded`); an entry with no subscription.
- [ ] **Step 2: Failing tests** (`SubscriptionStateStoreTests`): round-trip; a missing file returns the default; a corrupt file returns the default; `remove` deletes.
- [ ] **Step 3:** Implement. Pure, with no clocks inside: `now` is always passed in.
- [ ] **Step 4:** `xcodegen generate`; run both suites → PASS.
- [ ] **Step 5:** Commit: `feat: subscription schedule and per-device refresh state`.

### Task 4: Conditional fetch in `BoundedDownloader`

**Files:**
- Modify: `App/Services/BoundedDownloader.swift`
- Test: `AppTests/BoundedDownloaderTests.swift` (it already uses a `URLProtocol` stub; reuse it)

**Interfaces:**
- Produces:
  ```swift
  struct ConditionalResponse: Sendable {
      enum Body: Sendable { case notModified, data(Data) }
      let body: Body
      let etag: String?
      let lastModified: String?
      let httpExpires: Date?     // from Cache-Control max-age (relative to now) or the Expires header
  }
  static func fetchConditional(
      _ url: URL, etag: String?, lastModified: String?,
      maxBytes: Int, timeout: TimeInterval,
      followCrossHostRedirects: Bool = false,
      configuration: URLSessionConfiguration = .ephemeral,
      now: Date = .now
  ) async throws -> ConditionalResponse
  ```
  - `fetch(...)` keeps its signature and behaviour (it may delegate).

- [ ] **Step 1: Failing tests**:
  - `conditional_sendsIfNoneMatchAndIfModifiedSince` (the stub asserts both request headers).
  - `conditional_304_isNotModified`.
  - `conditional_200_returnsBodyAndHeaders` (`ETag`, `Last-Modified`, `Cache-Control: max-age=600` → `httpExpires == now+600`).
  - `conditional_expiresHeader_parsed` (RFC 1123 date).
  - `conditional_500_throwsHttpStatus`.
  - `conditional_oversize_throwsTooLarge`.
  - `conditional_crossHostRedirect_refused`.
- [ ] **Step 2:** `scripts/test.sh -only-testing:PinfoldTests/BoundedDownloaderTests` → FAIL.
- [ ] **Step 3:** Implement. `304` must be treated as success (`.notModified`) before the existing 2xx validation runs. `max-age` wins over `Expires`.
- [ ] **Step 4:** Run the suite → PASS. The existing tests still pass.
- [ ] **Step 5:** Commit: `feat: conditional GET with cache headers in BoundedDownloader`.

### Task 5: Refresh write path that keeps the person's choices

**Files:**
- Modify: `App/Services/NetworkLinkSnapshotService.swift` (`writeSnapshot`)
- Create: `App/Services/SubscriptionContentWriter.swift`
- Test: `AppTests/SnapshotWriteTests.swift`, new `AppTests/SubscriptionContentWriterTests.swift`

**Interfaces:**
- Consumes: `SubscriptionStateStore` (Task 3), `ImportResult`.
- Produces:
  - `nonisolated func writeSnapshot(_ result: ImportResult, to entry: CatalogEntry, storage: StorageLocations, resetResources: ResourceReset = .all) throws -> CatalogEntry`
  - `enum ResourceReset { case all, derivedOnly }`. `.derivedOnly` deletes everything in `resources/` except `SubscriptionStateStore.filename` and `download-state.json`. It then rebuilds derived data the way `ImportService.commit` does: KMZ extraction, the `PlacemarkIndex` write, the source stamp and the version stamp, plus `remote-hrefs.json` through `ResourceCache`. Builder's choice: call a shared helper extracted from `commit`.
  - `nonisolated func resolveOriginalConflicts(at url: URL) throws`: if `NSFileVersion.unresolvedConflictVersionsOfItem(at:)` is non-empty, keep the newest version (by `modificationDate`; replace the current version if a conflict version is newer), remove the others, and mark all of them resolved.
  - `enum SubscriptionContentWriter { static func apply(_ result: ImportResult, to entry: CatalogEntry, storage: StorageLocations, cache: ResourceCache) async throws -> CatalogEntry }`. Off-main through a `nonisolated` free function. It calls `resolveOriginalConflicts` and then `writeSnapshot(..., resetResources: .derivedOnly)`.

- [ ] **Step 1: Failing tests**:
  - `derivedOnly_keepsConsentAndState`: `download-state.json` with `consent: true` and `subscription-state.json` survive. `placemarks-index.v2.json` is rebuilt with the new placemarks. The source stamp equals the new SHA.
  - `derivedOnly_keepsNotesFavouritesTagsName`: the sidecar has notes, favourites, tags and a custom `displayName` → unchanged after the write. `contentSHA256`/`pointCount` updated.
  - `all_isUnchangedBehaviour`: the existing snapshot tests still pass with the default.
  - `kmz_derivedOnly_reextractsEmbedded`: a KMZ refresh puts the new embedded icon file in `resources/`.
- [ ] **Step 2:** Run `SnapshotWriteTests` + `SubscriptionContentWriterTests` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `xcodegen generate`; run → PASS.
- [ ] **Step 5:** Commit: `feat: refresh write path that keeps consent and refresh state`.

### Task 6: `SubscriptionRefresher`

**Files:**
- Create: `App/Services/SubscriptionRefresher.swift` (split into `+Timer.swift` if over the swiftlint file length)
- Modify: `App/Views/RootView.swift`, `App/Views/RootView+Storage.swift` (create, inject, start after bootstrap, scene-phase hooks), `App/Support/EnvironmentKeys.swift` if the environment is used
- Test: `AppTests/SubscriptionRefresherTests.swift`

**Interfaces:**
- Consumes: Tasks 2–5, `Catalog`, `ResourceCache`, `NetworkStatus`, `SpotlightIndexer`, `ImportService.prepare`.
- Produces:
  ```swift
  @MainActor @Observable final class SubscriptionRefresher {
      enum Phase: Equatable { case idle, refreshing, failed(String) }
      typealias Fetcher = @Sendable (URL, _ etag: String?, _ lastModified: String?) async throws -> ConditionalResponse
      init(catalog: Catalog, cache: ResourceCache, network: NetworkStatus?, fetcher: Fetcher? = nil, clock: @escaping () -> Date = { .now })
      private(set) var phases: [String: Phase]            // keyed by storageFolderName
      func phase(for entry: CatalogEntry) -> Phase
      func lastSuccess(for entry: CatalogEntry) -> Date?  // from the state file, cached in memory
      func start()                       // called once after bootstrap
      func sceneDidBecomeActive()        // refresh due + arm the timer
      func sceneDidResignActive()        // cancel the timer
      func refreshDue() async
      @discardableResult func refreshNow(_ entry: CatalogEntry) async -> Result<Void, SubscriptionError>
      func stopUpdating(_ entry: CatalogEntry) async throws
      func rearm()                       // recompute the timer after catalogue changes
  }
  enum SubscriptionError: Error, LocalizedError, Equatable {
      case http(Int), tooLarge, notSupported, linkOnly, network(String), writeFailed(String), readOnly
  }
  ```
  - The `.notSupported` message is "The server didn't return a KML, KMZ, GPX or GeoJSON file." `.linkOnly` is "The server returned a file that only links to other files."
- Behaviour, all from the spec's Refresher section:
  - Nothing runs before `start()`.
  - `refreshDue` skips entries that are not due or that are already refreshing.
  - At most 3 fetches run in parallel; writes are serialised.
  - Outcomes: `304` → state only. `200` with the same SHA as `entry.contentSHA256` → state only. `200` with new content → `ImportService.prepare` (off-main), then: link-only (0 placemarks and links present) → `.linkOnly`; failure → `.notSupported`; success → `SubscriptionContentWriter.apply`, `SpotlightIndexer.index`, `catalog.reload()`.
  - Errors record `lastError` and set `phases[...] = .failed`. Success clears both.
  - Before writing, re-read the live entry from `catalog.entries`. If it is gone, has no subscription, or is read-only, discard the result.
  - Storage: read `catalog.storage` at write time. Do not run while `StorageApplyQueue` is applying (expose or observe a flag; builder's choice).
  - Timer: one `Task` sleeping until the earliest `nextDue` (at least the floor), skipped while `network?.isOnline == false`, re-armed when it comes back online. Cancelled by `sceneDidResignActive`.
  - `stopUpdating` sets `subscription = nil` through `storage.updateExistingMetadata` (coordinated), removes the state file, reloads and re-arms.

- [ ] **Step 1: Failing tests** (stub fetcher, temp storage, injectable clock):
  - `nothingFetchedBeforeStart`.
  - `refreshDue_onlyDueEntries`: two subscribed entries, one checked a minute ago.
  - `refresh_304_updatesStateOnly`: `lastSuccessAt` set, original bytes unchanged.
  - `refresh_sameSHA_noWrite`: original file modification date unchanged, `resources/` untouched.
  - `refresh_changed_replacesAndKeepsAnnotations`: notes, favourites, tags and name survive. `pointCount` is updated. The catalogue reloads.
  - `refresh_htmlBody_keepsContentAndRecordsError`: `.failed`, original unchanged.
  - `refresh_linkOnly_isError`.
  - `refresh_http500_recordsError`.
  - `refresh_trashedEntry_skipped`.
  - `refresh_stopUpdatingMidFlight_doesNotRestoreSubscription`: the fetcher suspends; `stopUpdating` runs; resume → the sidecar subscription is still `nil` and the original is unchanged.
  - `refreshDue_twiceConcurrently_fetchesOnce` (the fetcher counts calls).
  - `refreshNow_ignoresDueButNotInFlight`.
  - `timer_armsForEarliestDue_andCancelsOnResign`: drive it with the clock plus a short test floor override, or assert the computed next fire date through an internal `nextFireDate` property.
  - `offline_skipsAndRearmsOnline`.
- [ ] **Step 2:** `scripts/test.sh -only-testing:PinfoldTests/SubscriptionRefresherTests` → FAIL.
- [ ] **Step 3:** Implement and wire into `RootView`: create it with the catalog, cache and network status; `start()` at the end of `bootstrap()`; `.active` → `sceneDidBecomeActive()` after the existing steps; `.inactive`/`.background` → `sceneDidResignActive()`. Inject it into the environment for the views.
- [ ] **Step 4:** Run the suite → PASS; `scripts/build.sh` → succeeds.
- [ ] **Step 5:** Commit: `feat: refresh online lists at launch, on foreground and on a timer`.

### Task 7: Subscribing (URL and link file)

**Files:**
- Create: `App/Services/SubscriptionService.swift`
- Modify: `App/Services/ImportCoordinator.swift`, `App/Services/ImportCoordinator+Downloads.swift`, `App/Services/ImportCoordinator+Commit.swift` (bypass the duplicate prompt for subscriptions), `App/Services/NetworkLinkSnapshotService.swift` (reuse `fetchURL`; remove the one-time-copy entry points the UI no longer uses)
- Test: `AppTests/SubscriptionServiceTests.swift`; update `AppTests/NetworkLinkSnapshotTests.swift`

**Interfaces:**
- Consumes: Tasks 2, 4, 6.
- Produces:
  ```swift
  enum SubscriptionURL {
      static func normalise(_ text: String) -> URL?   // trims; accepts http/https (any case) with a host; upgrades to https; nil otherwise
  }
  @MainActor struct SubscriptionService {
      init(catalog: Catalog, coordinator: ImportCoordinator, cache: ResourceCache, refresher: SubscriptionRefresher, fetcher: SubscriptionRefresher.Fetcher? = nil)
      enum Outcome: Equatable { case existing(UUID), converted(UUID), enqueued }
      func subscribe(to url: URL, origin: Subscription.Origin, link: KMLNetworkLink? = nil) async throws(SubscriptionError) -> Outcome
      func subscribeInPlace(_ entry: CatalogEntry, link: KMLNetworkLink) async throws(SubscriptionError)   // single-link card: this entry becomes the subscription
  }
  extension ImportCoordinator {
      func enqueueSubscribed(_ result: ImportResult, catalog: Catalog, cache: ResourceCache)  // result.subscription set; no duplicate prompt
  }
  ```
- `subscribe` order:
  1. A non-trashed entry with the same `subscription.url` → `.existing`.
  2. Download and prepare (link-only → `.linkOnly`).
  3. A non-trashed, non-online entry with the same SHA → write `subscription` into its sidecar → `.converted`.
  4. Otherwise `enqueueSubscribed` → `.enqueued`.
  - Link refresh hints are copied from `link` into the `Subscription`. The fetched validators (ETag and the other headers) are written to the new entry's state file after commit (builder's choice how; an acceptable fallback is the first refresh doing a full GET).
- `subscribeInPlace` uses `SubscriptionContentWriter.apply` with `.derivedOnly`, then sets `subscription` with origin `.networkLink`.

- [ ] **Step 1: Failing tests**:
  - `normalise_trimsAndUpgrades`: `"  HTTP://Example.com/a.kml \n"` → `https://Example.com/a.kml`.
  - `normalise_rejectsNonHTTP`: `webcal://x`, `file:///x`, `example.com`, `""` → nil.
  - `subscribe_sameURL_returnsExisting_noFetch`.
  - `subscribe_matchesStaticList_converts_keepsNotes`.
  - `subscribe_new_enqueuesAndCommitsWithSubscription_noDuplicatePrompt`: a trashed entry with the same SHA exists → `pendingDuplicate` stays nil and a new entry exists.
  - `subscribe_geoJSON_works`.
  - `subscribe_linkOnlyResponse_throws`.
  - `subscribeInPlace_replacesOriginalAndSetsSubscriptionWithHints` (`refreshMode`/`refreshInterval` copied).
  - `nothingIsFetchedWithoutCall` (kept from the 2.0 tests).
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `xcodegen generate`; run `SubscriptionServiceTests`, `NetworkLinkSnapshotTests`, `ImportCoordinatorTests` → PASS.
- [ ] **Step 5:** Commit: `feat: subscribe to a URL or a network link`.

### Task 8: + menu, URL alert, Mac command

**Files:**
- Modify: `App/Views/HomeView+Toolbar.swift`, `App/Views/HomeView.swift` (state), `App/Views/HomeView+Import.swift` (alert + action), `App/Model/WindowCommands.swift`, `App/Model/AppCommands.swift`
- Test: `AppTests/WindowCommandsTests.swift`

**Interfaces:**
- Consumes: `SubscriptionService`, `SubscriptionURL` (Task 7).
- Produces: `WindowCommands.subscribeToURL: () -> Void`. `canImport` also gates it.
- Behaviour:
  - **+ menu:** `Menu` with `Choose File…` (`doc`) → the existing importer; `Subscribe to URL…` (`globe`) → the alert. The label stays `plus`, with the same `.disabled` condition.
  - **Alert:** an `.alert` with a `TextField` (`.keyboardType(.URL)`, `.textInputAutocapitalization(.never)`, `.autocorrectionDisabled()`), using the copy from Global Constraints.
  - **On Subscribe:** normalise. Invalid → error alert `Enter a web address that starts with https://`. Valid → `SubscriptionService.subscribe`. `.existing`/`.converted` → select that entry. Errors → the existing catalogue error alert (or a local alert) with `localizedDescription`.
  - **Mac:** a File menu item `Subscribe to URL…` (⇧⌘N or no shortcut; builder's choice) via `AppCommands`.

- [ ] **Step 1: Failing test** `subscribeCommand_disabledWhileImporting` in `WindowCommandsTests`.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** Run the tests plus `scripts/build.sh` → PASS.
- [ ] **Step 5:** Commit: `feat: plus menu with Subscribe to URL`.

### Task 9: Catalogue row and long-press menu

**Files:**
- Modify: `App/Views/FileRow.swift`, `App/Views/HomeView+Sections.swift` (`activeRowMenu`), `App/Views/HomeView+Lists.swift` (pass phase/lastSuccess, confirmation dialog)
- Test: `AppTests/FileRowTextTests.swift` (new; test the pure text helper)

**Interfaces:**
- Consumes: `SubscriptionRefresher.phase(for:)`, `lastSuccess(for:)`, `refreshNow`, `stopUpdating`.
- Produces:
  - `FileRow(entry:, online: FileRow.OnlineStatus?)` where `enum OnlineStatus: Equatable { case idle(lastSuccess: Date?), refreshing, failed }`.
  - `static func secondaryLine(entry:, online:, now:) -> String`, which is pure and tested.
- Behaviour:
  - **Trailing glyph** before the system chevron: `globe` (idle), `ProgressView()` (refreshing), `exclamationmark.triangle` (failed, `.orange`), with the accessibility labels from the constraints.
  - **Second line:** `N points · Updated ⟨relative⟩` using `Date.RelativeFormatStyle` (named, abbreviated). It falls back to the import date when `lastSuccess` is nil. Failed → `N points · Couldn't update`.
  - **Long-press menu** for online entries: `Refresh Now` (`arrow.clockwise`), `Copy URL` (`link`, `UIPasteboard.general.url`), `Stop Updating` (`globe.badge.chevron.backward` or `xmark.circle`), placed before Trash. `Stop Updating` shows the confirmation dialog.
  - Trash rows show no online glyph.

- [ ] **Step 1: Failing tests**:
  - `secondaryLine_idle_showsUpdated`.
  - `secondaryLine_neverChecked_showsImportDate`.
  - `secondaryLine_failed_showsCouldntUpdate`.
  - `secondaryLine_offlineList_unchanged` (`online == nil` → today's text).
- [ ] **Step 2–4:** FAIL → implement → PASS; `scripts/build.sh`.
- [ ] **Step 5:** Commit: `feat: online status in catalogue rows`.

### Task 10: List screen ⋯ menu and reload on change

**Files:**
- Modify: `App/Views/KMLDetailView.swift` (toolbar item), new `App/Views/KMLDetailView+Subscription.swift`, `App/Views/KMLDetailView+Loading.swift` (reload when `entry.contentSHA256` changes)
- Test: `AppTests/DocumentLoadTests.swift` or new tests where logic is pure

**Interfaces:**
- Consumes: the refresher API (Task 6).
- Behaviour:
  - **⋯ menu** (`ellipsis.circle`): online entries only, placed before the sort menu.
    - Items: `Refresh Now`, `Copy URL`, `Stop Updating` (with confirmation).
    - While refreshing, the label is a `ProgressView` and `Refresh Now` is disabled.
    - A failed Refresh Now shows an alert with the error.
  - **Reload on change:** the view reloads its document when the live entry's `contentSHA256` differs from the one it loaded. Track `loadedSHA`. Use the existing `reloadDocument(for:)` path from `KMLDetailView+NetworkLinks.swift`, moved or shared.

- [ ] **Step 1:** If a pure helper is extracted (for example `needsReload(loadedSHA:live:)`), write its failing test first. Otherwise there is no new unit test; verification is the build plus the simulator check in the final screenshots task.
- [ ] **Step 2–4:** Implement → `scripts/build.sh` → the full `scripts/test.sh` still passes.
- [ ] **Step 5:** Commit: `feat: refresh menu on the list screen`.

### Task 11: Link card becomes Subscribe

**Files:**
- Modify: `App/Views/NetworkLinkPrompt.swift`, `App/Views/KMLDetailView+NetworkLinks.swift`, `App/Views/KMLDetailView.swift` (show condition)
- Test: `AppTests/NetworkLinkSnapshotTests.swift` (`NetworkLinkOffer` tests), or new `AppTests/NetworkLinkOfferTests.swift`

**Interfaces:**
- Consumes: `SubscriptionService.subscribe` / `subscribeInPlace` (Task 7).
- Produces:
  - `NetworkLinkOffer(document:)` is non-nil for any document with ≥1 fetchable link, including documents with placemarks.
  - `var replacesThisList: Bool { isSingle && placemarkCount == 0 }`.
- Behaviour:
  - Copy and buttons per Global Constraints. The icon is `globe`.
  - `replacesThisList` → `subscribeInPlace`. Otherwise `subscribe` per link, then report `Added N lists.`
  - The card is hidden once the entry itself is online.
  - The one-time `Download Copy` UI is removed.

- [ ] **Step 1: Failing tests**:
  - `offer_mixedDocument_isOffered_notReplacing`.
  - `offer_singleLinkOnly_replaces`.
  - `offer_noFetchableLinks_isNil`.
- [ ] **Step 2–4:** FAIL → implement → PASS; `scripts/build.sh`.
- [ ] **Step 5:** Commit: `feat: subscribe from a network-link file`.

### Task 12: Native Empty Trash

**Files:**
- Modify: `App/Views/TrashList.swift` (and `App/Views/HomeView+Toolbar.swift` if the toolbar must own it)

**Behaviour:**
- Remove the in-list `Section { Button("Empty Trash") }` row.
- Follow the iOS pattern used by Files, Notes and Photos ("Recently Deleted"): a red plain-text **Empty Trash** item in the **bottom toolbar**, right-aligned, shown only when the Trash segment is visible, Trash is non-empty, and select mode is off. Alternatively, a top-trailing toolbar text button if the bottom bar is taken.
- Add a list section footer: `Items in Trash can be restored or deleted permanently.`
- The existing confirmation dialog is unchanged.
- An empty Trash shows `ContentUnavailableView("Trash Is Empty", systemImage: "trash")` if no empty state exists yet.

- [ ] **Step 1:** Implement → `scripts/build.sh`.
- [ ] **Step 2:** Run the app on the simulator (run-sim skill) and screenshot Trash with items and empty; compare with the iOS Files app's Recently Deleted.
- [ ] **Step 3:** Commit: `fix: native Empty Trash control`.

### Task 13: Docs

**Files:**
- Modify: `skills/authoring-kml-for-pinfold/SKILL.md`, `CLAUDE.md` (Persistence & storage: `EntryMetadata.subscription`, `resources/subscription-state.json`, `SubscriptionRefresher`)

**Content:**
- NetworkLink is now a subscription refreshed while the app is open.
- It honours `refreshMode`, `refreshInterval`, `minRefreshPeriod` and `expires`.
- `Update`/`viewRefreshMode` are ignored.
- **Keep placemark `id`s stable across updates.**
- GeoJSON/URL subscriptions refresh hourly.
- Remove the "never fetched automatically / one-time download" wording.

- [ ] **Step 1:** Edit. **Step 2:** Commit: `docs: online lists in the authoring skill and CLAUDE.md`.
