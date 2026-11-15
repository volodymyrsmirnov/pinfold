# Map pin contrast — design

**Status:** owner feedback on device, 2026-11-15. Revises `2026-11-15-map-glass-pins-design.md`
(PR #9): the pin layout, optical sizing, favourite star, visited dimming, cluster bubbles
and late-icon swap stay; the backing changes.

## Why

On a real device (the owner's `belgium-2026` file, Material-style flat icons) the glass
pins failed three ways:
1. **Icons blended in.** The disc was tinted with the icon's own hue, so a red glyph sat
   on a red disc. Live Liquid Glass also adapted the colours of the icon drawn on it — red
   came out pink, blue cyan, amber lime (measured from the owner's screenshot; the
   simulator does not reproduce it). In light mode the pale glass gave little contrast.
2. **No air.** Icons filled the disc almost to the edge.
3. **Tap animation.** Interactive glass's press response delayed the place card.

## Design

- `PinDiscView` (replaces `GlassDiscView`): a plain, near-solid neutral disc — white 12 %
  at 92 % opacity in dark mode, white at 95 % in light mode — with a hairline edge (light on
  dark, dark on light) and a soft shadow. No tint, no live glass, so icons keep their exact
  colours and there is no blur cost; the 300-place flat fallback is gone.
- Selected: a 2 pt ring in the icon's hue (`IconPalette.accentColor`; the app tint for
  white, black or multi-colour icons), plus the existing scale-up.
- `IconPinAnnotationView` (replaces `GlassPinAnnotationView`): 34 pt disc; the icon fits an
  18 pt box and a 12 pt safe radius (`OpticalIcon.render(_:radius:maxSide:)`), so at least
  5 pt of air remains to the edge.
- `ClusterBubbleAnnotationView` (replaces `GlassClusterAnnotationView`): the same disc with
  the count; no tint.
