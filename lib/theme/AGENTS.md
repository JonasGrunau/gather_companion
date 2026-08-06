<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-08-05 | Updated: 2026-08-05 -->

# theme

## Purpose

The app's design tokens and the `ThemeData` built from them. Dark-only.

## Key Files

| File | Description |
|------|-------------|
| `gather_theme.dart` | `GatherTokens` (a `ThemeExtension` of flat colour tokens plus `radius`), `GatherTokens.dark`, the `context.tokens` accessor on `BuildContext`, and `buildGatherTheme()`. |

## For AI Agents

### Working In This Directory

- **The palette is Gather's own, read rather than eyeballed.** The accent is
  `--theme-color-accent: #4257DA`, taken from `app.v2.gather.town`'s stylesheet,
  with `brandSoft` (`#6886F2`) and `brandTint` (`#C2CEFB`) as steps of the same
  ramp. Type is Inter, matching Gather's interface, falling back to the system
  face. Do not substitute approximations.
- `primary` **is** the brand here — unlike Superset's near-white primary — because
  Gather's own UI leads with its accent. That divergence is intentional.
- Three text tiers exist: `foreground`, `mutedForeground`, and `faint` for
  timestamps, hints and chevrons. `border` and `ring` are *not* text colours; they
  are too dim to read.
- The file is deliberately shaped like Superset's `superset_theme.dart` — a
  `ThemeExtension` of flat tokens plus a `context.tokens` accessor — so the two
  companion apps stay legible to the same pair of eyes. Keep the structure even
  when the values differ.
- The token values are mirrored by hand in `tool/make_icons.mjs`, which draws the
  app icon from `background`, `brand`, `brandSoft`, `foreground` and `ok`.
  Changing a colour here means re-running the icon generator.
- Dark-only is a real assumption: `main.dart` sets `SystemUiOverlayStyle.light`
  once rather than deriving it, and the launch storyboard matches
  `GatherTokens.dark.background`. Adding a light theme means revisiting all three.

### Testing Requirements

No dedicated tests. Widget tests pull in `buildGatherTheme()` because the screens
read `context.tokens`; a missing token throws at build time, so
`flutter test` catches structural mistakes.

### Common Patterns

- Flat named colour tokens, no semantic nesting, no `MaterialColor` swatches.
- Every token that is not self-evident carries a doc comment saying where it is
  used and why it exists.

## Dependencies

### Internal

Read by everything in `../ui` via `context.tokens`, and by `../main.dart` for the
booting surface. Values duplicated in `tool/make_icons.mjs`.

### External

`flutter/material` only.

<!-- MANUAL: -->
