<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-08-05 | Updated: 2026-08-05 -->

# packages

## Purpose

Container for local Dart packages consumed by the Flutter app through path
dependencies. Not published to pub.dev.

## Subdirectories

| Directory | Purpose |
|-----------|---------|
| `gather_events/` | The wire models shared with the bridge — events and presence snapshots (see `gather_events/AGENTS.md`) |

## For AI Agents

### Working In This Directory

A package earns a place here when it is a *contract* rather than app code — the
one that exists is the Dart mirror of the bridge's JSON. Ordinary app logic
belongs in `lib/src`, not in a new package.

Any package added here needs a `path:` entry in the root `pubspec.yaml`.

<!-- MANUAL: -->
