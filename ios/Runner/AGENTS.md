<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-08-05 | Updated: 2026-08-05 -->

# Runner

## Purpose

The iOS app target. Almost entirely Flutter's generated scaffolding — the two
files that carry real decisions are `Info.plist` (permission copy, display name,
transport security) and the asset catalogue (written by `tool/make_icons.mjs`).

## Key Files

| File | Description |
|------|-------------|
| `Info.plist` | Display name, usage descriptions, local-networking exception, scene manifest, orientations. The hand-edited one. |
| `AppDelegate.swift` | Registers the generated plugin registrant via `FlutterImplicitEngineDelegate`. Otherwise stock. |
| `SceneDelegate.swift` | Empty `FlutterSceneDelegate` subclass, referenced by the scene manifest. |
| `GeneratedPluginRegistrant.h/.m` | Generated. Do not edit. |
| `Runner-Bridging-Header.h` | Generated. |
| `Assets.xcassets/` | `AppIcon.appiconset` (15 sizes) and `LaunchImage.imageset` — **all generated** by `tool/make_icons.mjs`. |
| `Base.lproj/` | `Main.storyboard` and `LaunchScreen.storyboard`. |

## For AI Agents

### Working In This Directory

- **`CFBundleDisplayName` is `Gather`, deliberately** — not "Gather Companion".
  The launcher clips at about ten characters and "Gather Companion" came out as
  "GatherCom…". The app introduces itself properly once opened; every other
  surface (in-app header, `MaterialApp.title`, permission copy) says the full
  name.
- **Two usage descriptions are required for the app to work at all:**
  `NSCameraUsageDescription` for scanning the pairing square, and
  `NSLocalNetworkUsageDescription` for reaching the bridge. Both are written as
  explanations a person would accept, and the local-network one matters — the
  first connection to a private address is what raises the prompt, and that
  attempt fails while the prompt is open (`lib/src/pairing.dart` has copy for
  exactly that case).
- `NSAllowsLocalNetworking` is set under `NSAppTransportSecurity` because the
  bridge is plain HTTP on the LAN. Do not broaden it to
  `NSAllowsArbitraryLoads`.
- `CFBundleShortVersionString` and `CFBundleVersion` interpolate
  `$(FLUTTER_BUILD_NAME)` and `$(FLUTTER_BUILD_NUMBER)`, which
  `flutter build ios --config-only --build-name --build-number` writes into
  `Flutter/Generated.xcconfig`. That is how the git tag and the CI run number
  become the version and build number. Do not hard-code either.
- **Never hand-edit the asset catalogue.** Re-run `node tool/make_icons.mjs`
  instead. Icon sizes are full-bleed squares because iOS applies the squircle
  itself.
- `ITSAppUsesNonExemptEncryption` is set so TestFlight does not ask on every
  upload.

### Testing Requirements

No tests here. Changes to `Info.plist` show up only in a real build:

```sh
flutter run -d <device>
tool/upload-testflight.sh --build
```

Permission-copy changes need a fresh install on a device to see the prompt again
— once granted or refused, iOS will not ask a second time.

### Common Patterns

- Generated Swift is left untouched; both delegates are the Flutter templates
  with no additions.

## Dependencies

### Internal

`Assets.xcassets` is produced by `tool/make_icons.mjs`. Version fields come from
`Flutter/Generated.xcconfig`, written by the release workflow.

### External

Flutter iOS embedding, `mobile_scanner` (camera), `flutter_local_notifications`
(alerts) — both registered through `GeneratedPluginRegistrant`.

<!-- MANUAL: -->
