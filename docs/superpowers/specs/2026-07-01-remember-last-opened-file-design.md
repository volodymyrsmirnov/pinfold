# Remember Last Opened File — Design

**Date:** 2026-07-01
**Status:** Superseded by `2026-07-02-session-restoration-design.md` (the implementation
described here never landed in the repository; the verified findings are carried forward)

## Problem

When iOS kills Pinfold in the background (e.g. the user opens a point, drives to it,
returns later), the app relaunches fresh at the catalogue with nothing selected. The user
has to re-find and reopen the file they were working with.

## Goal

On launch, restore the file that was selected when the app was last used — mirroring the
exact selection state at the time the app died. If nothing was selected (the user had gone
back to the catalogue), launch lands on the catalogue as today. Behavior is gated by a
Settings toggle, **on by default**. The user can always navigate back and open something
else; restore only sets the initial selection.

Also restored (added after the initial design shipped, at the user's request — helpful for
big files): the list scroll position within the restored file, via the topmost visible
outline row. Out of scope: restoring the open placemark (POI) page. Placemark-level restore
can be added later almost for free via the existing `pendingPlacemarkKey` deep-link hook.

## Approach

UserDefaults persistence via `AppSettings`, chosen over `@SceneStorage` (best-effort only —
iOS may discard scene state after force-quit or reboot, which is exactly the failure case
here) and `NSUserActivity` state restoration (heavyweight for one saved selection). The
saved identifier is the entry's `storageFolderName` — the same durable identifier the
Spotlight and App Intents deep links already use, with the same silent no-op resolution
against `catalog.active`.

## Design

### Settings model (`App/Model/AppSettings.swift`)

Two new UserDefaults-mirrored properties, following the existing `didSet` pattern:

- `rememberLastOpenedFile: Bool` — default **true**. Since `UserDefaults.bool(forKey:)`
  defaults to `false`, read it as `object(forKey:) as? Bool ?? true` (same shape as
  `entrySort`'s non-false default). Setting it to `false` also clears
  `lastOpenedEntryFolderName`.
- `lastOpenedEntryFolderName: String?` — the `storageFolderName` of the currently selected
  entry; `nil` when nothing is selected.

### Scroll position

`PlacemarkOutline.Row` ids are positional tree paths (`"0/1/p2"`), documented and verified
to be stable across launches because the tree is re-parsed identically from the same file —
so a row id is a durable scroll anchor.

- `AppSettings.lastOpenedScrollRowID: String?` stores the anchor beside the folder name.
  Writing a **different** folder name clears it (a scroll anchor is meaningless in another
  file); re-writing the same folder name preserves it; disabling the toggle clears it.
- **`@Observable` init gotcha (found during verification):** in an `@Observable` class,
  property observers DO fire for assignments inside `init` — so initializing the folder
  name from disk tripped the "different folder clears the anchor" coupling and deleted the
  saved anchor before it was ever read. Cross-property `didSet` side effects are therefore
  guarded by an `isBootstrapping` flag that init clears last; a regression test
  (`initWithSavedFolderAndAnchor_preservesAnchor`) pins the behavior.
- **Recording:** `KMLDetailView` tracks each realized row's top edge with per-row
  `onGeometryChange` into a non-observable `RowFrameBox` (per-frame writes must not
  invalidate the view tree). NOT the iOS 18 scroll-instrumentation APIs
  (`onScrollVisibilityChange` / `scrollPosition`): those do not support `List`
  (UICollectionView-backed; `ScrollView` only) and silently never fire — the original
  implementation used them and recorded nothing under real scrolling. At persist time the
  anchor is the row whose top is nearest the list's content top (offset by the calibrated
  restore landing position — see below). Recording only happens in the outline's default
  state (no search query, document-order sort — search/sort/collapse all reset on reopen
  anyway), and only on the `scenePhase` `.inactive` transition (always passed through on
  the way to background, before iOS's snapshot passes can re-lay the list out).
- **Restoring:** `RootView.restoreLastOpenedEntry()` reads the anchor before reselecting
  the entry and passes it to `KMLDetailView` as a one-shot `initialScrollRowID` (same
  consume-once pattern as `initialPlacemarkKey`). Applied via a `.task(id: rows.count)`
  (fires on appear AND on change — an `onChange` misses the transition on fast launches
  when the outline is built before the `List` attaches) with a verified retry:
  `ScrollViewReader.scrollTo(anchor, .top)` right after a `List`'s data lands is flaky, so
  the target row's live geometry is checked and the scroll re-issued (bounded) until it
  took. The successful landing offset is stored in `RowFrameBox.restoredTopOffset` to
  calibrate the persist reference. An anchor that no longer resolves is a silent no-op.
- **Known approximation:** position is restored to the nearest row boundary, and an
  async outline rebuild shortly after restore (e.g. the location fix arriving and adding
  distance labels) can shift the settled position by about one row. In normal use the
  layout has settled long before the app is backgrounded, so the recorded position is
  accurate.

### Recording (`App/Views/RootView.swift`)

Add `.onChange(of: selectedEntryID)`: when `rememberLastOpenedFile` is on, write the
selected entry's `storageFolderName` — or `nil` on deselect — to
`settings.lastOpenedEntryFolderName`. When the toggle is off, record nothing.

### Restoring (`App/Views/RootView.swift`)

At the end of `bootstrap()`, after `catalog.reload()`, restore only when ALL hold:

1. `rememberLastOpenedFile` is on;
2. `lastOpenedEntryFolderName` is non-nil;
3. `selectedEntryID` is still `nil` — a deep link (Spotlight tap, App Intent,
   "Open in Pinfold") that already drove a selection wins over restore.

Resolve the saved folder name against `catalog.active` and set `selectedEntryID`. On
compact width this drives the push into the file, the same proven flow as a Spotlight tap.

### Failure handling

A saved folder name that no longer resolves (entry deleted, trashed, or the storage root
switched) is a silent no-op: the app lands on the catalogue and the stale saved value is
cleared. No user-facing alert — consistent with existing deep-link behavior.

### Settings UI (`App/Views/SettingsView.swift`)

A new small section near the map-view section with
`Toggle("Remember Last Opened File", isOn: ...)` and a footer:
"Reopens the file you were viewing when the app restarts."

## Testing

- `AppSettings` unit tests with an injected `UserDefaults` suite: default-true read,
  persistence round-trip of both keys, and clear-on-disable.
- A `Catalog`-level test of the resolve-by-folder-name path (present, trashed, and missing
  entries) using the temporary `StorageLocations(root:)` pattern; suites sharing the
  `@MainActor` catalog are `@Suite(.serialized)`.
- The `RootView` restore guard stays a thin conditional, verified manually on the
  iOS 26.5 simulator (open file → relaunch → file restored; deselect → relaunch →
  catalogue; toggle off → relaunch → catalogue).
