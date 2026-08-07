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
| `gather_client/` | Gather V2's protocol in pure Dart: msgpack, the game socket, the presence fold, party mode (see `gather_client/lib/AGENTS.md`) |

## For AI Agents

### Working In This Directory

A package earns a place here when it is a *contract* rather than app code — the
two that exist are the Dart mirror of the bridge's JSON (`gather_events`) and
Gather's own protocol in Dart (`gather_client`). Ordinary app logic
belongs in `lib/src`, not in a new package.

Any package added here needs a `path:` entry in the root `pubspec.yaml`.

<!-- MANUAL: -->
