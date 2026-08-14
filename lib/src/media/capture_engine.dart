/// The one thing [MediaEngine] deliberately will not carry.
///
/// `media_engine.dart` keeps `MediaStream` out on purpose — a native handle on
/// that interface would drag `flutter_webrtc` into every file that reads capture
/// state, and the fake could no longer stand in. But two callers genuinely need
/// the handle: [SfuSession], which has to hand mediasoup a real track to publish,
/// and the preview widget, which has to point a renderer at something.
///
/// So the native half is a *second*, narrower interface, in a file that owns the
/// import. Everything that only cares about state still talks to [MediaEngine];
/// everything that needs the hardware itself asks for one of these. The gain is
/// small and specific: [LiveCall] can be built over a fake, which it could not
/// while it named [WebrtcMediaEngine] directly.
library;

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'media_engine.dart';

abstract class CaptureEngine implements MediaEngine {
  /// The live capture, or null when nothing is open.
  MediaStream? get localStream;
}
