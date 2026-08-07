/// The feed, kept on the phone.
///
/// The bridge used to hold a 500-event ring and replay it to a reconnecting app,
/// which was the only reason opening the app didn't show an empty screen. With the
/// app talking to Gather directly there is no such buffer to ask, so it keeps its
/// own — and the feed becomes a record of what *this phone* saw rather than what the
/// computer saw.
///
/// That is a real change in behaviour, and worth being clear about: activity while
/// the app was closed is gone unless a push recorded it. In exchange the feed
/// survives the computer being asleep, being on another network, or not existing.
///
/// ## Why not everything
///
/// The in-memory log holds a thousand events because scrolling is cheap. Writing a
/// thousand back to disk after every wave is not — each event is a JSON object and
/// `SharedPreferences` rewrites the whole plist on every commit. So the persisted
/// window is smaller, and writes are debounced: a burst of roster churn produces one
/// write, not forty.
library;

import 'dart:async';
import 'dart:convert';

import 'package:gather_events/gather_events.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How many events survive a restart.
///
/// Enough to open the app and see this morning; not so many that the plist rewrite
/// becomes something you can feel. The in-memory log is larger and is what the feed
/// actually scrolls.
const persistedEventLimit = 200;

/// How long to wait for the writes to stop before committing.
const _writeDebounce = Duration(seconds: 2);

class EventLogStore {
  EventLogStore({Future<SharedPreferences> Function()? prefs})
      : _prefs = prefs ?? SharedPreferences.getInstance,
        _enabled = true;

  /// A store that persists nothing.
  ///
  /// For widget tests, which have no business touching the disk and which fail
  /// outright on a timer that outlives the widget tree — and [save]'s debounce is
  /// exactly such a timer.
  EventLogStore.disabled()
      : _prefs = SharedPreferences.getInstance,
        _enabled = false;

  final Future<SharedPreferences> Function() _prefs;
  final bool _enabled;

  static const _key = 'feed.events';

  Timer? _pending;
  List<GatherEvent> _queued = const [];

  /// Newest first, matching the order the feed renders.
  Future<List<GatherEvent>> load() async {
    if (!_enabled) return const [];
    try {
      final prefs = await _prefs();
      final raw = prefs.getStringList(_key);
      if (raw == null || raw.isEmpty) return const [];

      final out = <GatherEvent>[];
      for (final line in raw) {
        try {
          out.add(GatherEvent.fromJson((jsonDecode(line) as Map).cast<String, Object?>()));
        } on Object {
          // One unreadable row should not cost the whole history. A shape that
          // changed between app versions decodes as a RawEvent or fails here; either
          // way the rest of the feed is still worth having.
          continue;
        }
      }
      return out;
    } on Object {
      return const [];
    }
  }

  /// Schedules a write. Repeated calls inside the debounce window collapse into one.
  void save(List<GatherEvent> events) {
    if (!_enabled) return;
    _queued = events;
    _pending?.cancel();
    _pending = Timer(_writeDebounce, flush);
  }

  /// Writes now. Called on the way to the background, where waiting two seconds for
  /// a debounce that may never fire would lose the tail of the session.
  Future<void> flush() async {
    if (!_enabled) return;
    _pending?.cancel();
    _pending = null;
    final events = _queued;
    if (events.isEmpty) return;

    try {
      final prefs = await _prefs();
      await prefs.setStringList(
        _key,
        events.take(persistedEventLimit).map((e) => jsonEncode(e.toJson())).toList(),
      );
    } on Object {
      // A failed write costs the user their scrollback, which is not worth an error
      // in front of them.
    }
  }

  Future<void> clear() async {
    if (!_enabled) return;
    _pending?.cancel();
    _pending = null;
    _queued = const [];
    try {
      final prefs = await _prefs();
      await prefs.remove(_key);
    } on Object {
      /* nothing useful to do */
    }
  }

  void dispose() {
    _pending?.cancel();
    _pending = null;
  }
}
