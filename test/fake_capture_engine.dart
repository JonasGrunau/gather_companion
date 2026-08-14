/// A [CaptureEngine] with no hardware and a stream made of nothing.
///
/// [FakeMediaEngine] already answers everything about *state*; this adds the one
/// thing [LiveCall] needs beyond it, which is a stream to hand to mediasoup. The
/// tracks in it are [FakeTrack]s: they have a kind and an id and nothing else,
/// which is all the publish path ever asks of them.
library;

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:gather_companion/src/media/capture_engine.dart';

import 'fake_media_engine.dart';
import 'fake_mediasoup.dart';

class FakeCaptureEngine extends FakeMediaEngine implements CaptureEngine {
  @override
  MediaStream? get localStream => state.capturing
      ? FakeStream(
          audio: state.audioTrackId != null,
          video: state.videoTrackId != null,
        )
      : null;
}
