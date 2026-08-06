<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-08-05 | Updated: 2026-08-06 -->

# gather_events

## Purpose

The Dart half of the wire contract between the bridge and the app. Every event
the bridge publishes and every field of the presence snapshot, as a sealed class
hierarchy the app can switch over exhaustively.

This package is the mirror of `bridge/lib/events.js` and the `snapshot` frame
built by `bridge/lib/presence.js`. There is no code generation and no shared
schema file — the two sides are kept in step by hand.

## Key Files

| File | Description |
|------|-------------|
| `pubspec.yaml` | `gather_events`, `publish_to: none`, Dart SDK `^3.12.0`. Dev-only deps (`lints`, `test`) — no runtime dependency, not even Flutter. |
| `analysis_options.yaml` | `package:lints`, separate from the app's `flutter_lints`. |
| `CHANGELOG.md` | Stub. |
| `README.md` | The package's own documentation: why the contract is written twice, the full event and snapshot tables, the fidelity enums, and the five-step recipe for adding an event type. Keep it in step with the models. |

## Subdirectories

| Directory | Purpose |
|-----------|---------|
| `lib/` | The barrel export and the implementation (see `lib/AGENTS.md`) |

## For AI Agents

### Working In This Directory

- **This package must not depend on Flutter.** It is plain Dart so the models
  stay usable outside a widget tree (and so tests over them are fast). Nothing
  here should import `package:flutter`.
- **Changing a field name is a two-sided change.** Update
  `bridge/lib/events.js`, this package, and the event-type list in the root
  `README.md` together. The bridge will keep emitting the old name with no error
  and the app will silently decode nulls.
- Decoding is forgiving on purpose: `EventSource.parse` and `Confidence.parse`
  fall back rather than throw, and unmodelled event types land in `RawEvent`, so
  a bridge newer than the app degrades instead of crashing the feed.
- Adding an event type means adding a subclass here; the app's `lookOf()` switch
  in `lib/src/relevance.dart` is exhaustive, so the analyzer will point at the
  place that needs a matching case.

### Testing Requirements

The package has no tests of its own. It is exercised through the app:

```sh
flutter test        # relevance_test.dart constructs these models directly
```

`test/relevance_test.dart` and `test/feed_screen_test.dart` are the de-facto
coverage. `dev_dependencies` includes `test:` if unit tests are ever added here.

### Common Patterns

- `sealed class GatherEvent` with one subclass per wire type; each carries
  `type`, `summary`, `payload()` and inherits `toJson()`.
- Named constructors for decoding, `const` constructors and `copyWith` on the
  presence models.

## Dependencies

### Internal

Consumed by `lib/` (the app) via a path dependency declared in the root
`pubspec.yaml`. Mirrors `bridge/lib/events.js`.

### External

None at runtime. `lints` and `test` for development.

<!-- MANUAL: -->
