<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-08-05 | Updated: 2026-08-05 -->

# lib

## Purpose

The package's public surface: a barrel file over the two implementation
libraries.

## Key Files

| File | Description |
|------|-------------|
| `gather_events.dart` | The only public entry point. Exports `src/events.dart` and `src/presence.dart`. |

## Subdirectories

| Directory | Purpose |
|-----------|---------|
| `src/` | The models themselves (see `src/AGENTS.md`) |

## For AI Agents

### Working In This Directory

Consumers import `package:gather_events/gather_events.dart` and nothing else —
never a `src/` path directly. A new source file needs an `export` line here or it
is invisible to the app.

<!-- MANUAL: -->
