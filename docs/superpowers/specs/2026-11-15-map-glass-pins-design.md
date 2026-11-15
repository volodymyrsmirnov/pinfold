# Map glass pins — design

**Status:** approved by the owner after a simulator/device prototype · 2026-11-15. Backing revised by `2026-11-15-map-pin-contrast-design.md` (no live glass, no tint).
Supersedes `2026-11-15-map-pin-badges-design.md` (solid badges), which was built, then
replaced after the owner compared both on device.

## Why

KML icons were drawn raw on the map and blended into the basemap. Solid badges fixed
contrast but recoloured icons and erased white detail. The owner prefers the file's own
icon, in its own colours, on a Liquid Glass disc, and asked for the clusters to match.

## Design

**Pin** (`GlassPinAnnotationView`, every pin whose style has a cached icon; the teardrop
fallback for icon-less styles is unchanged):
- 32 pt round disc of iOS 26 Liquid Glass (`UIGlassEffect(.regular)`, interactive, so it
  responds to touch like system glass) — the shared `GlassDiscView`.
- Faint tint in the icon's own hue (30 % alpha; none for white, grey, black or multi-hue
  icons — `IconPalette`), so categories read at a glance.
- Hairline edge (light on dark maps, dark on light maps) and a soft drop shadow, so the disc
  stays separate on any basemap.
- The icon keeps its colours. It is sized **optically** (`OpticalIcon`): transparent padding
  is trimmed, the visible shape is centred, and it is scaled so its farthest visible pixel
  sits 12.5 pt from the centre — every icon looks the same size and stays 3.5 pt clear of
  the edge, whether or not the file padded it.
- Favourite: a small yellow star badge on the disc's top-right rim. Visited: icon at 45 %.
- Selected: tint to 60 %, a 2 pt ring in the tint colour (accent when untinted), plus the
  existing scale-up.

**Clusters** (`GlassClusterAnnotationView`): the same glass disc, 36 pt tall, growing into a
capsule for 3+ digit counts, with the member count in a rounded semibold label. Tinted with
the members' shared hue when more than half of them share one tint; otherwise plain glass.

**Flat fallback:** live glass costs a blur per view. Files with more than 300 placemarks use
a pre-drawn translucent disc (near-white in light mode, near-black in dark) with the same
tint, edge, shadow and badges. Rendering is otherwise identical.

**Icons arriving late:** when a style's icon finishes downloading while the map is open, the
pin's teardrop view is replaced by a glass pin (the annotation is re-added, keeping
selection).

## Non-goals

Zoom-dependent pin sizing, appear animations and muting Apple's own places (follow-ups the
owner deferred); the teardrop fallback; list-row icons.

## Removed

`PinBadge` (solid / plate badges) and its silhouette helpers. `IconBitmap` and
`IconPalette` stay: they now feed the tint and the optical sizing.
