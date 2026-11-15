# Map Pin Badges Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Draw every href-backed KML icon on the map inside a 28 pt badge — solid
(icon color fill, white or dark silhouette, white ring) for single-color icons, a white
plate with the original icon for multi-color ones.

**Architecture:** A new pure-drawing `PinBadge` enum in `App/Support/PinBadge.swift`
classifies an icon bitmap and renders the badge. `PlacemarkPinImage.image(for:…)` wraps
the loaded icon with it instead of only resizing. Everything downstream (base-image cache,
`decorated`, `PinDecorationCache`, centre anchor) is unchanged.

**Tech Stack:** Swift 6, UIKit `UIGraphicsImageRenderer` / CoreGraphics, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-15-map-pin-badges-design.md`

## Global Constraints

- Badge diameter **28 pt**; solid-badge glyph ≈ **16 pt**; plate icon ≈ **18 pt**; ring **2 pt** white; shadow = the teardrop's (`offset (0,1)`, blur 2, black 35 %).
- Badges stay `.center`-anchored. The teardrop fallback (`fallbackImage`) is not touched.
- Fill priority: KML `iconColor` (when set, not white, not fully transparent) → icon's own color → accent color when that color is near-white.
- Build/test only via `scripts/build.sh`, `scripts/test.sh`; `swiftlint lint` stays at 0 errors.

## Review Focus

- An icon with no opaque pixels (blank PNG) → plate badge, no crash or division by zero.
- A white `wht-blank`-style glyph with no tint → solid badge with accent fill, white glyph visible.
- A KML tint with alpha `00` or the default `ffffffff` → ignored (treated as no tint).
- A black glyph → black fill, white glyph, white ring still separates it from a dark map.
- A wide, non-square icon → aspect-fit inside the disc, not stretched.

---

### Task 1: `PinBadge` — classify and draw

**Files:**
- Create: `App/Support/PinBadge.swift`
- Test: `AppTests/PinBadgeTests.swift`

**Interfaces:**
- Produces:
  - `enum PinBadge`
  - `static let diameter: CGFloat = 28`
  - `static func dominantColor(of icon: UIImage) -> UIColor?` — the icon's color if it is single-color, `nil` if multi-color or blank.
  - `static func fillColor(kmlTint: UIColor?, iconColor: UIColor, fallback: UIColor) -> UIColor`
  - `static func glyphColor(onFill fill: UIColor) -> UIColor` — `.white`, or near-black (`UIColor(white: 0.1, alpha: 1)`) when the fill's relative luminance > 0.6.
  - `static func badge(for icon: UIImage, kmlTint: UIColor?, fallback: UIColor) -> UIImage` — the one entry point Task 2 calls.

- [ ] **Step 1: Write the failing tests** in `AppTests/PinBadgeTests.swift` (a `struct PinBadgeTests`). Build icons in-test with `UIGraphicsImageRenderer` (a filled circle in one color; a half-red/half-blue square; a fully clear image; a 40×10 bar). Compare colors by RGBA components with tolerance 0.05.
  - `dominantColor_singleColorIcon` → ≈ the drawn color (orange `#E8740C`).
  - `dominantColor_twoColorIcon_isNil`
  - `dominantColor_blankIcon_isNil`
  - `fillColor_prefersKMLTint` → tint returned when tint is red.
  - `fillColor_ignoresWhiteAndTransparentTint` → for `.white` and `UIColor.red.withAlphaComponent(0)` tints, returns iconColor.
  - `fillColor_nearWhiteIconUsesFallback` → iconColor white, no tint → fallback.
  - `glyphColor_darkOnYellow_whiteOnOrange` → yellow `#F5C400` gives dark, orange gives `.white`.
  - `badge_isDiameterSquare` → for single-color, two-color, blank and wide icons, `size == CGSize(width: 28 + 2*margin, height: 28 + 2*margin)` with `margin` read from `PinBadge.margin` (expose it `static let margin: CGFloat = 3`).
  - `badge_solidCenterIsFill` → sample the pixel at 4 pt left of the centre of a single-color-icon badge: ≈ the fill or glyph colour, **not** white plate. (Read pixels via `cgImage` + `CGContext` into an RGBA buffer; add a small test helper.)
  - `badge_multiColorHasWhitePlate` → a pixel just inside the ring of a two-color badge is ≈ white.

- [ ] **Step 2: Run to verify failure**
  Run: `scripts/test.sh -only-testing:PinfoldTests/PinBadgeTests`
  Expected: build failure, `cannot find 'PinBadge' in scope`.

- [ ] **Step 3: Implement `PinBadge`.**
  - `dominantColor`: draw the icon aspect-fit into a 16×16 RGBA8 premultiplied bitmap; take pixels with alpha ≥ 128 (un-premultiply); if fewer than 4, return `nil`; mean RGB; single-color when ≥ 90 % of those pixels lie within Euclidean RGB distance 0.2 (0…1 scale) of the mean.
  - `fillColor`: use `kmlTint` unless it is `nil`, alpha < 0.05, or all of r,g,b > 0.95; else `iconColor`, unless `iconColor` is near-white (min(r,g,b) > 0.85) → `fallback`.
  - Solid badge: shadowed disc in fill, 2 pt white ring stroke, then the icon aspect-fit into a 16 pt centred square recoloured with `glyphColor` (draw image, then fill its rect with `.sourceIn`, in its own transparency layer so the disc isn't affected).
  - Plate badge: shadowed white disc, 0.5 pt `UIColor(white: 0, alpha: 0.2)` hairline, original icon aspect-fit into an 18 pt centred square.
  - `badge(for:)`: `dominantColor` non-nil → solid with `fillColor(kmlTint:iconColor:fallback:)`; nil → plate. **Exception:** a non-nil, not-ignored `kmlTint` on a multi-color icon still uses the plate (the tint can't be recovered from a multi-color bitmap).

- [ ] **Step 4: Run to verify pass**
  Run: `scripts/test.sh -only-testing:PinfoldTests/PinBadgeTests`
  Expected: all `PinBadgeTests` pass.

- [ ] **Step 5: Commit**
  `git add App/Support/PinBadge.swift AppTests/PinBadgeTests.swift Pinfold.xcodeproj/project.pbxproj && git commit -m "feat: PinBadge — solid or plate badge for KML icons"`

### Task 2: Use the badge for href-backed pins

**Files:**
- Modify: `App/Support/PlacemarkPinImage.swift` (`image(for:…)` href branch; `resized` and the `dimension` docs)
- Test: `AppTests/PlacemarkPinImageTests.swift` (header comment only — the href path still needs on-disk files)

**Interfaces:**
- Consumes: `PinBadge.badge(for:kmlTint:fallback:)`, `UIColor(kmlHex:)` (`App/Support/KMLColor.swift`).

- [ ] **Step 1: Replace** `return (resized(image, maxDimension: dimension), .center)` with `return (PinBadge.badge(for: image, kmlTint: style?.iconColor.flatMap(UIColor.init(kmlHex:)), fallback: UIColor(Color.accentColor)), .center)`. Delete `resized` if unused; update the type doc (resolution order step 1) to describe the badge.

- [ ] **Step 2: Run the full suite and lint**
  Run: `scripts/test.sh` then `swiftlint lint --quiet | grep -c error:`
  Expected: `** TEST SUCCEEDED **`; lint error count `0`.

- [ ] **Step 3: Verify on the simulator** (run-sim skill) with a file whose icons are Google My Maps glyphs plus a multi-color pushpin (`AppTests/Fixtures/Rome.kmz` or `iceland-trip-2026.kml` if they carry icons; otherwise build a scratch KMZ from the screenshot's style). Check standard and dark map: orange glyphs show as orange discs with white glyphs, pushpins sit on white plates, favorite star still at top-right, tapping a pin still selects it.

- [ ] **Step 4: Commit**
  `git add App/Support/PlacemarkPinImage.swift AppTests/PlacemarkPinImageTests.swift docs/superpowers && git commit -m "feat: badge KML icons on the map for legibility"`
