/// Somewhere the media log survives long enough to be read off the device.
///
/// `debugPrint` is the obvious sink and it is not enough here. In a profile or
/// release build Flutter routes `print` through the engine's logging callback
/// into `os_log`, not the process's stdout — so `devicectl … --console`, which
/// bridges stdout and stderr, shows every `NSLog` the WebRTC plugin makes and
/// not one line of Dart. That was not a detail: it cost a whole debugging round
/// on 2026-09-17, where the only evidence of a call was the camera's native
/// format line and the app's own account of what it did was invisible.
///
/// So every line also goes to a file. `Directory.systemTemp` on iOS is the app
/// sandbox's `tmp/`, which means no `path_provider` dependency and a path that
/// `devicectl` can reach:
///
/// ```sh
/// xcrun devicectl device copy from --device <udid> \
///   --domain-type appDataContainer --domain-identifier com.jonasgrunau.gatherCompanion \
///   --source tmp/media.log --destination ./media.log
/// ```
///
/// Truncated on every launch rather than appended to, because a log that has to
/// be read by eye is only useful if it covers one run. It is opened lazily and
/// written synchronously: this is a diagnostic, and a diagnostic that loses the
/// last few lines to a buffer is worthless precisely when it matters — the lines
/// just before a hang are the ones being looked for.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';

/// The log file for this run, or `null` if the device would not give us one.
IOSink? _sink;
bool _tried = false;

/// Where the log is being written, for the code that wants to say so out loud.
String? mediaLogPath;

/// [debugPrint], plus a copy on disk that outlives the console.
///
/// Every failure here is swallowed. Losing the file copy of a log should never
/// be the reason a call does not connect.
void mediaLog(String line) {
  debugPrint(line);
  mediaLogToFile(line);
}

/// The file half alone, for callers that must not go back through `print`.
///
/// The zone in `main.dart` captures `print` so that libraries which report their
/// failures that way — mediasoup's `FlexQueue` swallows every exception and
/// `print`s it under `kDebugMode`, which is the only account anyone gets of why
/// a `produce` never happened — land in this file too. Routing that through
/// [mediaLog] would call `debugPrint`, which calls `print`, which re-enters the
/// zone: one library error and the app spins forever.
void mediaLogToFile(String line) {
  if (!_tried) {
    _tried = true;
    try {
      final file = File('${Directory.systemTemp.path}/media.log');
      _sink = file.openWrite(mode: FileMode.write);
      mediaLogPath = file.path;
    } on Object {
      _sink = null;
    }
  }

  final sink = _sink;
  if (sink == null) return;
  try {
    sink.writeln('${DateTime.now().toIso8601String()} $line');
  } on Object {
    _sink = null;
  }
}
