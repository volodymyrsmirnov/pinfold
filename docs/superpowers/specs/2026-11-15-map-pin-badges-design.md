# Map pin badges — design

**Status:** superseded by `2026-11-15-map-glass-pins-design.md` · 2026-11-15

## Why

A file's own KML icon goes on the map raw: shrunk to 24 pt, centre-anchored, with no
backing (`PlacemarkPinImage.image(for:…)`). Google My Maps-style icons (an orange
fork and knife, a cocktail glass) blend into the basemap, especially the dark one, and
are hard to pick out next to Apple's own places. The owner wants pins that read clearly on
any map style.

## Goals

- Every href-backed pin has a solid backing that stands out on light, dark, satellite and
  hybrid maps.
- The icon's meaning stays recognizable: same glyph, same color family as the file intended.
- No change in how pins behave: anchoring, favorite star, visited dimming, selection,
  clustering and batching all keep working.

**Non-goals:** the teardrop fallback (files without icons) already has an outline and stays
as it is; cluster bubbles; icons in list rows (`StyleIcon`); hiding Apple's places (possible
later as a separate setting).

**Anti-goals:** no blur or glass per pin (too costly with thousands of pins, and contrast
would still depend on the map underneath); a badge must never make its icon unreadable
(a white glyph on a white disc, a white blob for a photo icon).

## Approaches

- **A · Solid badge** *(picked, with B as fallback)*: a disc filled with the icon's color,
  with the icon redrawn as a white silhouette and a white ring. Highest contrast. Works
  only for single-color icons.
- **B · White disc**: the original icon drawn as-is on a white disc. Works for any icon,
  less punchy. Used when A can't apply.
- **C · Glass disc**: rejected (see anti-goals).
- **D · Teardrop marker** (`MKMarkerAnnotationView` + glyph): rejected. It's the largest
  shape, clusters sooner and has A's silhouette limitation, and the only thing it adds is
  the selection animation.

## Design

For an href-backed icon, analyse the decoded bitmap once per style (it's already cached
by `PlacemarkPinImage.CacheKey`), then draw one of two badges:

1. **Classify** (`IconPalette`). Look at the icon's opaque pixels by **hue**. Near-black
   pixels count as outline or detail, and white or grey ones are neutral. If the colored
   pixels share one hue, the icon is **single-color** and gets badge A. A mostly white or grey
   icon counts as white, and a mostly dark one as black. If the colored pixels span several
   hues (photos, multi-colored emoji-style icons), it gets badge B. *Builder's call, after
   simulator testing:* a plain RGB-distance test sent every real My Maps glyph and classic
   Google icon to B, because of their black outlines and gradients.
2. **Badge A, solid.**
   - Fill: the style's `iconColor` when set (KML tints the icon with it, so this is
     the color the author meant); otherwise the icon's own color. If that color is
     near-white (a `wht-blank`-style icon with no tint), use the accent color, the same
     default the teardrop uses.
   - Glyph: the icon's alpha mask filled white, or dark when the fill is light (yellow),
     chosen by luminance so it always contrasts. Near-black outline and detail are knocked
     out of the mask, so the fill shows through (a pushpin's star or a pin's hole survives).
     A black icon keeps its whole mask.
   - Shape: **28 pt** disc (up from 24 pt), glyph about 16 pt, 2 pt white ring, the same
     soft drop shadow as the teardrop.
3. **Badge B, white disc.** A 28 pt white disc with a hairline outline and the same
   shadow, with the original icon about 18 pt inside.
4. Both are **centre-anchored** as today. `decorated(…)` (star, visited alpha) and
   `PinDecorationCache` apply on top unchanged.

**Trade-off accepted:** larger pins collide a little sooner, so clustering kicks in slightly
earlier when it's on.

## Left to the builder

- The exact single-color test (pixel sample size, color-distance threshold, how much
  anti-aliased edge and dark outline to tolerate), pinned down by unit tests on synthetic
  icons: one color (A), two strong colors (B), white with no tint (A with accent fill),
  light fill (dark glyph).
- The near-white and light-fill luminance cut-offs.
- Verify on the simulator with the Brussels-style file on the standard and dark maps.
