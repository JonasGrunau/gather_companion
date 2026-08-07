<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-08-05 | Updated: 2026-08-05 -->

# .github

## Purpose

The release pipeline. One workflow, three jobs, one git tag that ships both
halves of the product: `gather-app-bridge` to npm and Gather Companion to
TestFlight.

## Key Files

| File | Description |
|------|-------------|
| `workflows/publish.yml` | Named `release`, filename `publish.yml`. Jobs: `test` (the gate), `npm`, `ios`. Triggered by `v*` tags and `workflow_dispatch`. Every non-obvious decision is documented in a long header comment inside the file. |

## How a release works

```sh
# bump "version" in package.json, commit, then:
git tag -a v0.2.0 -m "gather-app-bridge 0.2.0"
git push --tags
```

- The **tag is the single source of truth**. `v0.2.0` publishes the bridge as
  `0.2.0` and builds the app as `0.2.0`, with the workflow run number as
  `CFBundleVersion`. `version:` in `pubspec.yaml` is not read by a release.
- The `test` job runs `npm test` plus `flutter analyze` / `flutter test` on
  `macos-latest`. **Neither half ships if it is red**, so a tag can never produce
  a release that exists on npm but not TestFlight.
- It also fails fast if the tag disagrees with `package.json` — npm versions are
  immutable, so that check has to happen before either publish.
- Re-runs are safe: the `npm` job asks the registry whether the version already
  shipped and skips if so, and a re-run gets a fresh build number.

## For AI Agents

### Working In This Directory

- **The workflow file must stay `publish.yml`.** npm's trusted-publisher entry
  matches the `job_workflow_ref` OIDC claim, which carries the file *path*, not
  the `name:`. Renaming the file fails publishing with `404 … package not found`,
  which reads like a missing package rather than an auth failure. Renaming the
  workflow itself is free.
- **The owner field in npm's trusted-publisher entry is case-sensitive**:
  `JonasGrunau`, matching the `repository_owner` claim. Getting it wrong cost six
  red runs and presents as the same misleading 404.
- **`id-token: write` is load-bearing.** There is no `NPM_TOKEN` anywhere — npm
  mints a short-lived credential from the OIDC token GitHub provides.
- **The Gather client's tests need their own `dart pub get`.** A path dependency
  does not get its `dev_dependencies` resolved by the root `flutter pub get`, and
  `flutter analyze` reads the whole tree — so without that step every
  `package:test` import under `packages/*/test` is an unresolved URI and analysis
  fails with ~224 errors before a line of app code is read. It also means those
  tests were not running at all, which is why the step runs `dart test` too: they
  are the only coverage the Gather protocol has, and the app now depends on it.
- `npm publish` runs at `--loglevel verbose` on purpose: npm reports OIDC
  failures at verbose level *only*. The line that matters is `npm verbose oidc`.
  `--provenance` is explicit because trusted publishing did not attach it on its
  own.
- **Six repository secrets**, none of them for npm: `ASC_KEY_ID`,
  `ASC_ISSUER_ID`, `ASC_KEY_P8` for the upload, and `APPLE_DIST_CERT_P12`,
  `APPLE_DIST_CERT_PASSWORD`, `APPLE_PROVISIONING_PROFILE` for signing.
- The iOS job reconstructs the layout a developer Mac already has —
  `~/.appstoreconnect/private_keys/AuthKey_<id>.p8` and
  `~/.appstoreconnect/issuer_id` — specifically so it can run
  `tool/upload-testflight.sh` unchanged rather than maintaining a second
  implementation that drifts.
- The certificate is imported into a **throwaway keychain** created for the run,
  with `set-key-partition-list` so `codesign` does not block on a UI prompt
  nobody can answer, and a `find-identity` check that fails the job immediately
  rather than ten minutes later in the export.
- Flutter (`3.44.5`) and Xcode are both pinned. A runner-image roll must not be
  able to change the toolchain a release was built with. Keep the pin in step
  with `.tool-versions`.
- `concurrency` is grouped by ref and does **not** cancel in progress — two tags
  pushed together would otherwise race for the same build number.
- Signing details (why manual, what expires when) live in `../ios/AGENTS.md` and the
  README's Releasing section.

### Testing Requirements

There is no way to test this except by running it:

```sh
gh workflow run publish.yml    # dispatch: version comes from package.json
gh run watch
```

A failed run can be re-run from the Actions tab without inventing a second tag.
The IPA and packaging logs are uploaded as an artifact even on failure — when App
Store Connect rejects an upload, that log is the difference between reading why
and rebuilding blind.

### Common Patterns

- Every non-obvious step carries a comment explaining the failure it prevents.
  This file is documentation as much as configuration; keep it that way.

## Dependencies

### Internal

Runs `npm test`, `flutter analyze`/`flutter test`, and `tool/upload-testflight.sh`.
Exports through `ios/ExportOptions.plist`. Reads the version from
`package.json`.

### External

`actions/checkout@v6`, `actions/setup-node@v6`, `subosito/flutter-action@v2`,
`maxim-lobanov/setup-xcode@v1`, `actions/upload-artifact@v4`. npm trusted
publishing, and the App Store Connect API.

<!-- MANUAL: -->
