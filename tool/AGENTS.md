<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-08-05 | Updated: 2026-08-05 -->

# tool

## Purpose

Two developer scripts: the one that draws the app icon, and the one that ships a
build to TestFlight. Neither is part of the app or the npm package.

## Key Files

| File | Description |
|------|-------------|
| `probe-events.mjs` | The instrument that found Gather's event bus. Prints the full model census, dumps the interaction-shaped models whole, then watches **every** delta patch and bus event unfiltered — which is what `probe-connect.mjs` structurally could not do, since it pipes frames through the four-model reader. Read-only observer; never sends `enterSpace`. |
| `make_icons.mjs` | Draws the icon from constants and writes all fifteen asset-catalogue sizes, the launch mark on alpha, and the squircled `docs/icon.png`. Zero dependencies — the PNG encoder is `node:zlib` plus a CRC table. |
| `upload-testflight.sh` | Uploads `build/ios/ipa/gather_companion.ipa` via `xcrun altool`. **CI runs this exact script**, so the human path and the automated path cannot drift. |
| `icon-preview.png` | Output of `--preview`, committed for review. |

## For AI Agents

### Working In This Directory

**`make_icons.mjs`**

- The mark is a ping on a 32×32 pixel grid: you are the white block in the
  centre, and the green marker is somebody who has attached themselves to you.
  Pixel geometry nods at the tile-grid medium while borrowing nothing from
  Gather's own mark.
- The palette constants are copied by hand from `lib/theme/gather_theme.dart`.
  Changing a token there means updating them here and re-running.
- **Catalogue sizes stay full-bleed squares.** iOS applies the squircle itself; a
  pre-rounded tile is masked twice and comes out with chewed corners. Only the
  README copy carries the mask in its pixels, because GitHub strips the CSS that
  would otherwise round it.
- Writes into `ios/Runner/Assets.xcassets/AppIcon.appiconset`. Another platform
  target needs a matching output path added here.

```sh
node tool/make_icons.mjs --preview
```

**`upload-testflight.sh`**

- The App Store Connect **issuer ID lives in `~/.appstoreconnect/issuer_id`**,
  not in the repo — it is account-level and shared with the Superset app.
  `altool` already reads private keys from that directory by convention, so the
  issuer sits next to them. The script fails with instructions if it is missing.
- `KEY_ID` defaults to `9FVGFF4ZJ8` (Gather) and is overridable via `ASC_KEY_ID`,
  which is how CI supplies whatever its secret holds.
- The version and build number are read **out of the IPA's `Info.plist`**, not
  from `pubspec.yaml` — those disagree the moment someone bumps a version without
  rebuilding, and App Store Connect rejects a duplicate build number.
- `--build` runs `flutter build ipa --export-options-plist ios/ExportOptions.plist`
  so a local build is packaged exactly the way CI packages one. Never let it fall
  back to Flutter's generated export options.
- Requires the distribution certificate in the login keychain and the profile in
  `~/Library/MobileDevice/Provisioning Profiles`. See `../ios/AGENTS.md`.

```sh
tool/upload-testflight.sh --build
```

### Testing Requirements

Neither script has automated tests. Verify by inspection:
`node tool/make_icons.mjs --preview` and then look at `tool/icon-preview.png`;
for the uploader, a real TestFlight build is the only test, so read it carefully
before changing it — CI depends on it.

### Common Patterns

- Zero dependencies, same as the bridge.
- Long header comments explaining why the script exists at all, not just what it
  does.
- `set -euo pipefail` and `mktemp` with a `trap` cleanup in the shell script.

## Dependencies

### Internal

`make_icons.mjs` → `ios/Runner/Assets.xcassets/`, `docs/icon.png`, and the token
values in `lib/theme/gather_theme.dart`.
`upload-testflight.sh` → `ios/ExportOptions.plist`, `build/ios/ipa/`, and is
invoked by `.github/workflows/publish.yml`.

### External

Node 22+ (`node:zlib`). Xcode command line tools (`xcrun altool`, `plutil`,
`unzip`), and Flutter for `--build`.

<!-- MANUAL: -->
