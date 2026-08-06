<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-08-05 | Updated: 2026-08-05 -->

# ios

## Purpose

The iOS runner for Gather Companion, and — more importantly for anyone editing
here — the signing and export configuration that both CI and a local Mac build
depend on. Most of this directory is Flutter-generated Xcode scaffolding; the one
hand-written, load-bearing file is `ExportOptions.plist`.

Bundle id `com.jonasgrunau.gatherCompanion`, team `JQ4STVWTQ3`, minimum iOS 15.5
(required by `mobile_scanner`).

## Key Files

| File | Description |
|------|-------------|
| `ExportOptions.plist` | How the archive becomes an uploadable IPA. **Manual signing**, explicit certificate and profile. Used by both `.github/workflows/publish.yml` and `tool/upload-testflight.sh`. |

## Subdirectories

| Directory | Purpose |
|-----------|---------|
| `Runner/` | The app target: delegates, `Info.plist`, asset catalogue (see `Runner/AGENTS.md`) |
| `RunnerTests/` | Flutter's default XCTest stub. Not used — the real tests are Dart. |
| `Flutter/` | Generated xcconfigs and the ephemeral SPM package tree. Never edit; `flutter build ios --config-only` writes it. |
| `Runner.xcodeproj/`, `Runner.xcworkspace/` | Xcode project and workspace. `xcodebuild` is driven against the **workspace**. |

## For AI Agents

### Working In This Directory

- **Swift Package Manager, not CocoaPods.** `mobile_scanner` 7.x is a Swift
  package. There is no `Podfile` and re-adding the CocoaPods integration breaks
  the build with a misleading *"missing expected TARGET_BUILD_DIR"*. Version 7
  also dropped GoogleMLKit, which had no arm64 simulator slices — on 6.x the app
  could not run on an arm64 simulator at all.
- **Signing is manual on purpose, and this is the single most expensive thing to
  re-learn.** Automatic signing asks Apple to update the Xcode-managed profile
  during export; that is a *cloud signing* operation and an App Store Connect API
  key is never permitted to perform one — it fails with `Cloud signing permission
  error` however the key is scoped (tested with Admin access, full Certificates/
  Identifiers/Profiles access, warm and cold profile caches). It works on a
  developer Mac only because Xcode holds an Apple ID session, which a runner has
  no equivalent of.
- **`manageAppVersionAndBuildNumber` must stay `false`,** or Xcode rewrites the
  build number during export and the workflow's run number stops being the build
  number.
- **CI archives unsigned and signs during export.** A command-line signing
  setting applies to every target in the workspace, and the Flutter plugins are
  Swift packages, which reject it outright ("mobile_scanner does not support
  provisioning profiles"). Signing the `Runner` target alone is not expressible
  from the command line, so `CODE_SIGNING_ALLOWED=NO` on the archive and one
  signing step at export is the working shape.
- **The build is deliberately not `flutter build ipa` in CI.** That would use
  Flutter's own generated export options instead of this file.
  `flutter build ios --config-only` writes the project configuration and
  `xcodebuild` is driven directly.
- **The certificate and profile expire 2027-08-05** and are reissued together:
  `Apple Distribution` for `JQ4STVWTQ3`, and the App Store profile *Gather
  Companion App Store* bound to it. Reissuing means refreshing the three
  `APPLE_*` repository secrets and re-importing the `.p12` locally.

### Testing Requirements

There is nothing to unit-test here. Verify changes by producing an actual build:

```sh
tool/upload-testflight.sh --build      # local: build + upload through this plist
gh workflow run publish.yml            # CI: the same path, from secrets
```

To sideload for development instead: open `Runner.xcodeproj`, set a signing team
on the `Runner` target, then `flutter run -d <device>`. A free Apple ID works for
personal device installs.

### Common Patterns

- Generated files are left exactly as Flutter writes them; hand-written intent
  goes into `ExportOptions.plist`, which carries a long XML comment explaining
  every non-default key.

## Dependencies

### Internal

`tool/upload-testflight.sh` and `.github/workflows/publish.yml` both export
through `ExportOptions.plist`. `tool/make_icons.mjs` writes into
`Runner/Assets.xcassets`.

### External

Xcode (pinned to `latest-stable` in CI), Flutter 3.44.5, an Apple Distribution
certificate and the matching App Store provisioning profile.

<!-- MANUAL: -->
