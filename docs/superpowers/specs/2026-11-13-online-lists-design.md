# Online lists: subscribe to a URL and full NetworkLink refresh (Pinfold 2.1)

**Date:** 2026-11-13
**Release:** 2.1

## Why

The owner wants to keep a KML (or GeoJSON) file on their own server, have an LLM update it there,
and have Pinfold pick up the changes on its own: no re-uploading, no re-importing. 2.0 can only
take a one-time copy of a file a `<NetworkLink>` points at, and says plainly that it "never
fetches this automatically". 2.1 adds **online lists**: lists that follow a URL and refresh
themselves while the app is in use.

## Goals

- Two ways to get an online list:
  1. **Import a KML/KMZ that contains `<NetworkLink>`s**, then tap **Subscribe** on the card the
     list already shows for link files.
  2. **Subscribe to a URL** of a KML, KMZ or GeoJSON file (GPX works too, because import detects
     the format from the content).
- The **+** button becomes a menu: **Choose File…** / **Subscribe to URL…**. The URL option opens
  a system alert with a text field.
- An online list refreshes **at launch, each time the app returns to the foreground, and on a timer
  while the app stays open** (a Mac or iPad can stay in the foreground for hours). It refreshes
  only when it is due under the file's `refreshMode`/`refreshInterval` and the server's
  `<NetworkLinkControl>` `minRefreshPeriod`/`expires` hints.
- **A list's name is set once, when you subscribe.** A later change to the server's `<name>` does
  not rename it. The person can rename it like any other list. (Owner's default, 2026-11-13.)
- In the catalogue, an online list shows a **globe** just before the chevron. While it refreshes, a
  **spinner** takes the globe's place. When the last check failed, a **warning** icon does.
- A **⋯ menu** in an online list's toolbar has **Refresh Now**, **Copy URL** and **Stop Updating**.
  The catalogue row's long-press menu gets the same three items.
- A refresh keeps everything the person made: notes, favourites, visited marks, tags and a rename.

## Non-goals (2.1)

- **No background refresh.** Lists refresh only while the app is open. No `BGAppRefreshTask`, no
  push, no APNs.
- **No sign-in.** No usernames, passwords, auth headers or token fields. A secret token inside
  the URL is the only "auth".
- **No Google Earth tree model.** A link is never a folder inside another list. Each URL is
  exactly one list.
- No `viewRefreshMode` / bounding-box queries, `viewFormat`, `httpQuery` or cookies.
- No `<NetworkLinkControl><Update>` (`Create`/`Change`/`Delete` diffs). Every refresh replaces the
  whole file. A conditional request makes the "nothing changed" case cost almost nothing.
- Links inside a fetched file are **not followed**.
- No UI to edit the refresh interval, and no notification when a list changes.

## Anti-goals (a failure even if it technically works)

- A refresh that drops notes, favourites, visited marks, tags or the person's rename.
- A bad server response (an error, garbage, an oversized file) that breaks or empties a working
  list. The last good copy must stay.
- Any request made without the person's explicit **Subscribe** tap. Importing a link file alone
  must not fetch anything.
- Refreshes taking over the import UI: no import progress bar, no disabled **+**, and never
  blocked behind a duplicate-import prompt.
- Hammering a server or the battery because a file asks for `refreshInterval` 1.

## Constraints from the existing app

- **The catalogue lives in per-entry folders on disk.** `metadata.json` is the synced sidecar, and
  `resources/` is a local-only cache. The parsed tree is re-parsed from disk on open.
- **2.0 devices rewrite `metadata.json` with only the fields they know.** `EntryMetadata` has
  hand-written Codable, and `JSONDecoder` drops unknown keys. A 2.0 device that edits a list
  (tags, rename, trash, favourites) therefore drops the subscription from the synced sidecar,
  and the list stops updating on every device. **The owner accepted this** (2026-11-13): most
  people will move to 2.1, and the subscription lives in `metadata.json`.
- **The 2.0 snapshot path already replaces an entry's original in place**
  (`NetworkLinkSnapshotService.replaceOriginal` → `writeSnapshot`). It is crash-ordered, touches
  only the content fields of the sidecar (`sourceFilename`, `pointCount`, `contentSHA256`), and
  leaves tags, favourites, notes and trash state alone. It then **deletes all of `resources/`**.
  That is too much for a refresh (see Writing a refresh).
- **Downloads go through `BoundedDownloader`:** ephemeral session, no cookies, a 50 MB cap,
  `http` upgraded to `https`, and no cross-host redirects for network links. Today it returns
  only the body: no status other than 2xx, no response headers, no conditional requests.
- **Import goes through `ImportCoordinator`**, which is held until storage bootstrap resolves the
  root. **`StorageApplyQueue` serialises storage changes.** `RootView` already reacts to
  `scenePhase == .active`.
- **Annotations are keyed by placemark `stableKey`.** Notes on keys that no longer resolve are kept
  and shown in the orphaned-notes section. Notes survive a refresh only if the server keeps
  placemark `id`s stable.

## Approaches considered

- **A. A separate `SubscriptionRefresher` (chosen).** A `@MainActor @Observable` service owns the
  refresh schedule and per-list state (refreshing, failed, last checked). It fetches due lists and
  writes changed content through the snapshot write path. New subscriptions still go through
  `ImportCoordinator`.
  *Trade-off:* a second writer next to the import queue. That is acceptable because a refresh only
  ever rewrites an existing folder's original, and imports only create new folders.
- **B. Send refreshes through the `ImportCoordinator` queue.** One writer for everything. But every
  silent refresh would show import progress and disable **+**, and a pending duplicate prompt would
  block all refreshes. That works against the anti-goals.
- **C. Treat each refresh as a fresh import that replaces the old entry.** Reuses the most code,
  but the list's identity changes on every refresh, which breaks Spotlight, the open screen and
  iCloud. Rejected.

For the model itself, the owner chose the **subscription model (one URL = one list)** over the
Google Earth tree model.

## Design

### Parser (`PinfoldCore`)

- `KMLNetworkLink` gains `refreshMode: RefreshMode?` (`onChange`, `onInterval`, `onExpire`) and
  `refreshInterval: TimeInterval?`, read from `NetworkLink > Link` (and the legacy `Url`).
  Unknown or missing values become `nil`.
- `KMLDocument` gains `networkLinkControl: KMLNetworkLinkControl?` with `minRefreshPeriod:
  TimeInterval?` and `expires: Date?` (an XML `dateTime`). Everything else under
  `<NetworkLinkControl>` is ignored, including `Update`, `cookie`, `message` and `linkName`.
- GPX and GeoJSON readers are unchanged. They carry no refresh hints.

### Storage

**Synced: `EntryMetadata.subscription: Subscription?`** in `metadata.json`. Fields:
- `url`: the URL as the person or file gave it.
- `origin`: `url` or `networkLink`.
- `subscribedAt`.
- `refreshMode?` and `refreshInterval?`: copied from the link when the subscription came from
  a `<NetworkLink>`.

Rules:
- Decoded with `decodeIfPresent` and encoded only when non-nil, so the sidecars of normal lists
  don't change. Update `CodingKeys`, `init(from:)`, `encode(to:)` and the memberwise init, as the
  `EntryMetadata` comment requires.
- **iCloud conflict merge:** a scalar, so the current version wins, as for `displayName`.
- Every write goes through the existing coordinated read-modify-write
  (`updateExistingMetadata`), so a concurrent tag or note edit is never lost.
- `Stop Updating` sets it to `nil`.
- `CatalogEntry` gains `subscription: Subscription?`, copied from the sidecar like `tags`.

**Local only: `resources/subscription-state.json`.** Fields: `lastAttemptAt`, `lastSuccessAt`,
`lastError?`, `etag?`, `lastModified?`, and the server hints from the last fetch:
`NetworkLinkControl` `minRefreshPeriod`/`expires`, plus HTTP `Cache-Control: max-age` /
`Expires`. Each device keeps its own.

### When a list is due

A pure function, table-tested:

- `onInterval`: `refreshInterval`.
- `onExpire`: the `NetworkLinkControl` `expires`, else the HTTP expiry, else the default.
- `onChange`, no mode, plain URL and GeoJSON subscriptions: the **default of 1 hour**.
- **Floor:** never more often than `max(5 minutes, minRefreshPeriod)`.
- A failed check is due again once the floor has passed.
- **Never due:** trashed lists and read-only lists (sidecar not readable or not yet downloaded).

### Refresher

- **Starts after `bootstrap()`.** At launch, and on every `scenePhase == .active` (after the
  existing re-resolve, drain and reload steps), it checks all due lists. It never runs while
  `StorageApplyQueue` is applying a storage change. It reads `catalog.storage` when it writes.
- **In-session timer.** While the scene is active, a single timer is armed for the earliest
  next-due time among online lists (never sooner than the 5-minute floor). When it fires, it runs
  the same due check.
  - The timer is cancelled when the scene goes inactive or to the background.
  - It is re-armed after every refresh, subscribe, Stop Updating, trash, restore and catalogue
    reload.
  - When the device is offline (`NetworkStatus`), firing is skipped; the timer re-arms when the
    device comes back online.
  - It runs no work outside the foreground.
- **Refresh Now** skips the due check but still respects an in-flight refresh. It does not
  respect the floor: the person asked.
- **Fetch:** a conditional GET (`If-None-Match` / `If-Modified-Since`) through `BoundedDownloader`,
  extended to send extra request headers, treat `304` as "not modified", and return the response
  headers. The rest of the hardening stays as it is: 50 MB cap, ephemeral, no cookies, `https`
  upgrade, cross-host redirects refused.
- **Outcomes:**
  - `304`: update the state only.
  - `200` whose SHA-256 equals the entry's `contentSHA256`: update the state only. This covers
    another device having already written the same content through iCloud.
  - `200` with new content: validate with `ImportService.prepare` (any supported format), then
    write it (next section).
  - Validation failure, HTTP error, a file over 50 MB, or a network error: record `lastError` and
    leave the list untouched.
  - **A fetched file that has no placemarks of its own but does contain network links** is an error
    ("The server returned a file that only links to other files"). Links are not followed.
  - **A valid file with zero placemarks** is accepted: the server owns the content, and notes
    survive as orphans.

### Writing a refresh

- Reuse `writeSnapshot`'s crash-ordered replace and its owned-fields-only sidecar update. **Do
  not delete all of `resources/`:**
  - **Keep** `subscription-state.json` and any per-list choices the person made that live there
    (for example remote-image consent in `download-state.json`; the builder confirms which files
    hold choices).
  - **Rebuild** data derived from the original: the placemark index (its source-SHA stamp already
    forces a rebuild), files extracted from a KMZ, and the manifest.
- Then re-index Spotlight for the entry and reload the catalogue.
- An open `KMLDetailView` for that entry reloads its document when the entry's `contentSHA256`
  changes, as it already does after a snapshot.
- A list trashed while its refresh is in flight still gets the write (trash is only a flag). A
  list permanently deleted mid-flight fails quietly.

### Subscribing

**Subscribe to URL:**
1. **+** is now a `Menu`: **Choose File…** (`doc`) and **Subscribe to URL…** (`globe`). It keeps
   today's disabled conditions.
2. The alert, titled *Subscribe to URL*, has a text field with the placeholder
   `https://example.com/map.kml`. Its message reads: *"Pinfold will check this address for
   updates while the app is open. The host can see your device's IP address."* Buttons: Cancel /
   Subscribe.
3. Only `http(s)` URLs with a host are accepted; anything else shows an error. `http` is upgraded
   to `https`.
4. If a non-trashed list already follows the same normalised URL, that list is selected and no new
   one is made.
5. Otherwise the file is downloaded and enqueued on `ImportCoordinator` as a downloaded item that
   **carries the subscription**, so the commit writes the sidecar with `subscription` set. It shows the normal import progress and errors.
6. The name comes from the document name, else the URL's last path component, else the host. This
   is the existing import naming.

**From a link file:** the 2.0 card (`NetworkLinkPrompt`) changes:
- It shows whenever the document has fetchable links, **including files that also have their own
  placemarks**. In 2.0 it appeared only for link-only files.
- Copy: *"This file links to online data. Subscribe to keep it updated from ⟨hosts⟩. Pinfold
  checks for changes while the app is open. The host can see this device's IP address."*
- **One link, no placemarks of its own:** a **Subscribe** button. This list becomes the
  subscription: the original is replaced by the fetched file, as in 2.0, and `subscription` is set
  with the link's refresh settings.
- **Several links, or links plus placemarks of its own:** a **Subscribe to N Lists** button. Each
  link becomes a new online list through the import queue. The file itself stays as it is.
- The one-time **Download Copy** goes away. **Stop Updating** gives the same static result.
- Importing a link file never fetches by itself. The tap on **Subscribe** is the consent.

### Catalogue row (`FileRow`)

```
│ [map]  Hiking ideas              🌐   ›  │   idle
│        42 points · Updated 10 min ago    │
│ [map]  Hiking ideas              ◌    ›  │   refreshing
│ [map]  Hiking ideas              ⚠︎    ›  │   last check failed
│        42 points · Couldn't update       │
```

- The trailing status glyph sits just before the chevron, for online lists only.
- The second line's date becomes **"Updated ⟨relative⟩"**: the last successful check on this
  device. Until this device has checked, it falls back to the import date.
- Each glyph has an accessibility label ("Online list", "Updating", "Couldn't update").
- The long-press menu gains **Refresh Now**, **Copy URL** and **Stop Updating** for online lists.

### List screen (`KMLDetailView`)

- **Online lists only:** a ⋯ toolbar `Menu` with **Refresh Now**, **Copy URL** and **Stop
  Updating**. While refreshing, its label is a small `ProgressView` and Refresh Now is disabled.
- When Refresh Now fails, an alert shows the error. Success is silent: the list reloads.
- **Stop Updating** asks first: *"Stop updating "⟨name⟩"? The current copy stays as a normal
  list."* It then clears `subscription` and deletes the local state.

### iCloud: several devices, one subscription (builder's call)

- **Every 2.1 device that has the subscription fetches and writes.** A subscription
  arriving through sync counts as consent: it is the same person's iCloud account, and they
  tapped Subscribe on one of their devices. A single "writer device" was rejected because the list
  would silently stop updating once that device is gone.
- **The app resolves conflicts only for `metadata.json` today, not for originals.** Before
  writing, the refresher resolves any unresolved `NSFileVersion` conflicts on the original:
  newest modification wins, and the other versions are removed and marked resolved. It then
  writes the new bytes. A sidecar `contentSHA256` that disagrees with the bytes on disk costs at
  most one extra write on the next refresh, and derived data already rebuilds from the
  placemark index's source-SHA stamp.

### Subscribing to content that is already in the catalogue (builder's call)

- **New subscriptions skip `ImportCoordinator`'s SHA-256 duplicate prompt.**
- If the fetched content matches a **non-trashed list that is not online**, that list *becomes*
  the online list: its sidecar gets `subscription`, and its notes, favourites,
  tags and name are kept. This is what someone upgrading from 2.0's one-time "Download Copy"
  expects.
- In every other case (no match, a trashed match, or a match that is already an online list for a
  different URL), a new list is created.

### Mac (Designed for iPad)

- The File menu gets **Subscribe to URL…** next to Import, through `WindowCommands`.

### Mixed versions

- **A 2.0 device** sees an online list as a normal file. Its content still changes when a 2.1
  device refreshes and iCloud syncs the original. If the 2.0 device edits the list, the
  subscription is dropped. The owner accepted this.

### Docs

- `skills/authoring-kml-for-pinfold/SKILL.md`:
  - NetworkLink is now a subscription, refreshed while the app is open, honouring `refreshMode`,
    `refreshInterval`, `minRefreshPeriod` and `expires`.
  - `Update` and view-based refresh are ignored.
  - **Keep placemark `id`s stable** across updates so notes and favourites survive.
  - GeoJSON and plain URL subscriptions refresh hourly.
- The in-app privacy wording lives on the card and the alert. `PrivacyInfo` needs no change: no
  data is collected, and requests go only to hosts the person chose.

## Tests

- **Parser:**
  - `refreshMode` / `refreshInterval` under both `Link` and legacy `Url`.
  - Unknown mode → `nil`.
  - `NetworkLinkControl` `minRefreshPeriod` / `expires`.
  - An `Update` block is ignored without breaking the parse.
- **Due-date function:** a table covering every mode, the floor, server hints, failure retry,
  and that trashed and read-only lists are never due.
- **`Subscription` in `EntryMetadata`:** round-trip; a legacy sidecar without it decodes; the
  sidecar of a normal list is byte-identical to 2.0's; merge keeps current's; the scanner
  populates `CatalogEntry.subscription`.
- **Refresher with a stub downloader:**
  - `304` → no write.
  - `200` with the same SHA → no write.
  - `200` with changed content → original replaced; notes, favourites, tags, rename and
    remote-image consent kept; index rebuilt.
  - HTTP error, garbage or oversize → content untouched, `lastError` set.
  - A link-only response → error.
  - Trashed lists are skipped.
  - No fetch happens before bootstrap.
  - Timer: armed for the earliest due list, cancelled when inactive, skipped when offline,
    re-armed after a refresh. Use an injectable clock.
- **`BoundedDownloader`:** conditional headers are sent; `304` is surfaced; response headers are
  returned. Use a `URLProtocol` stub.
- **Subscribe flow:** an invalid URL is rejected; a duplicate URL selects the existing list; a new
  URL commits with `subscription` in the sidecar.
- **Link card:** single link → this entry becomes the subscription; several links / mixed → N new
  lists; nothing is fetched before the tap.

## Left to the builder

- File layout and type names, apart from those fixed above.
- How `BoundedDownloader` exposes headers and 304: a new result type or an overload.
- How many lists are fetched in parallel. Writes are serialised either way.
- Exactly which `resources/` files hold the person's choices and must survive a refresh.
- How `KMLDetailView` notices that its entry changed.
- Final copy for errors and accessibility labels.
- The `MARKETING_VERSION` bump to 2.1 happens at release time, per CLAUDE.md, not in this work.
