/// mediasoup, with no platform channel behind it.
///
/// `Device.load()` asks an `RTCPeerConnection` what the platform can encode, and
/// `transport.produce()` builds a real sender — neither exists under
/// `flutter test`. Everything [SfuSession] is actually *about*, though, is
/// ordinary logic: which node somebody is on, what to do when a socket comes
/// back, whether a `consume-try` means build a consumer or close one. This is
/// what lets that half be tested.
///
/// These fake the library's classes with `implements` plus [noSuchMethod] rather
/// than reimplementing them. That is deliberate: the compiler checks the members
/// we *do* override against the real signatures, so a library upgrade that
/// changes one of them breaks here rather than on a device.
library;

import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:gather_companion/src/media/mediasoup_ice.dart';
import 'package:mediasfu_mediasoup_client/mediasfu_mediasoup_client.dart' as ms;

/// A [ms.Device] that loads instantly and hands back [FakeTransport]s.
class FakeDevice implements ms.Device {
  bool _loaded = false;

  /// The capabilities we were loaded with, so a test can assert we passed on
  /// what the SFU actually said.
  ms.RtpCapabilities? loadedWith;

  final List<FakeTransport> transports = [];

  /// Every `createSendTransport`/`createRecvTransport` call, in order.
  final List<({String direction, String id, List<RTCIceServer> iceServers})>
      created = [];

  @override
  bool get loaded => _loaded;

  @override
  Future<void> load({required ms.RtpCapabilities routerRtpCapabilities}) async {
    loadedWith = routerRtpCapabilities;
    _loaded = true;
  }

  @override
  ms.RtpCapabilities get rtpCapabilities => ms.RtpCapabilities.fromMap(const {
        'codecs': <Map<String, dynamic>>[],
        'headerExtensions': <Map<String, dynamic>>[],
      });

  @override
  ms.Transport createSendTransport({
    required String id,
    required ms.IceParameters iceParameters,
    required List<ms.IceCandidate> iceCandidates,
    required ms.DtlsParameters dtlsParameters,
    ms.SctpParameters? sctpParameters,
    List<RTCIceServer> iceServers = const [],
    RTCIceTransportPolicy? iceTransportPolicy,
    Map<String, dynamic> additionalSettings = const {},
    Map<String, dynamic> proprietaryConstraints = const {},
    Map<String, dynamic> appData = const {},
    Function? producerCallback,
    Function? dataProducerCallback,
  }) {
    created.add((direction: 'send', id: id, iceServers: iceServers));
    final transport = FakeTransport(id: id, producerCallback: producerCallback);
    transports.add(transport);
    return transport;
  }

  @override
  ms.Transport createRecvTransport({
    required String id,
    required ms.IceParameters iceParameters,
    required List<ms.IceCandidate> iceCandidates,
    required ms.DtlsParameters dtlsParameters,
    ms.SctpParameters? sctpParameters,
    List<RTCIceServer> iceServers = const [],
    RTCIceTransportPolicy? iceTransportPolicy,
    Map<String, dynamic> additionalSettings = const {},
    Map<String, dynamic> proprietaryConstraints = const {},
    Map<String, dynamic> appData = const {},
    Function? consumerCallback,
    Function? dataConsumerCallback,
  }) {
    created.add((direction: 'recv', id: id, iceServers: iceServers));
    final transport = FakeTransport(id: id, consumerCallback: consumerCallback);
    transports.add(transport);
    return transport;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class FakeTransport implements ms.Transport {
  FakeTransport({required this.id, this.producerCallback, this.consumerCallback});

  @override
  final String id;

  @override
  final Function? producerCallback;

  @override
  final Function? consumerCallback;

  @override
  bool closed = false;
  int iceRestarts = 0;
  List<RTCIceServer> lastIceServers = const [];

  /// The handlers [SfuSession] registered, so a test can fire `connect` and
  /// `produce` the way a real transport would.
  final Map<String, Function> handlers = {};

  final List<FakeProducer> producers = [];
  final List<FakeConsumer> consumers = [];

  @override
  void on(String event, Function handler) => handlers[event] = handler;

  @override
  void produce({
    required MediaStreamTrack track,
    required MediaStream stream,
    List<ms.RtpEncodingParameters> encodings = const [],
    ms.ProducerCodecOptions? codecOptions,
    ms.RtpCodecCapability? codec,
    bool stopTracks = true,
    bool disableTrackOnPause = true,
    bool zeroRtpOnPause = false,
    Map<String, dynamic> appData = const {},
    required String source,
  }) {
    // The real transport asks the server for an id before it builds anything,
    // through the `produce` handler, and only then calls the callback. Doing the
    // same here is what makes the session's `produce` message get sent at all.
    final handler = handlers['produce'];
    final tag = (appData['tag'] as String?) ?? source;
    Future<void>(() async {
      var id = 'producer-$tag';
      if (handler != null) {
        final completer = _Completer();
        await handler({
          'kind': track.kind,
          'rtpParameters': ms.RtpParameters.fromMap(const {
            'codecs': <Map<String, dynamic>>[],
            'headerExtensions': <Map<String, dynamic>>[],
            'encodings': <Map<String, dynamic>>[],
            'rtcp': {'cname': 'fake', 'mux': true, 'reducedSize': true},
          }),
          'appData': appData,
          'callback': completer.callback,
          'errback': completer.errback,
        });
        // The real transport awaits this and lets the error out of the task —
        // no producer is built and the callback never fires. Anything friendlier
        // here would hide the twenty-second hang that behaviour used to cause.
        final Object? chosen;
        try {
          chosen = await completer.future;
        } on Object {
          return;
        }
        if (chosen is String) id = chosen;
      }
      final producer = FakeProducer(id: id, tag: tag, encodings: encodings);
      producers.add(producer);
      producerCallback?.call(producer);
    });
  }

  @override
  void consume({
    required String id,
    required String producerId,
    required String peerId,
    required RTCRtpMediaType kind,
    required ms.RtpParameters rtpParameters,
    Map<String, dynamic> appData = const {},
    Function? accept,
  }) {
    final consumer = FakeConsumer(
      id: id,
      producerId: producerId,
      appData: appData,
    );
    consumers.add(consumer);
    consumerCallback?.call(consumer, accept);
  }

  @override
  void updateIceServers(List<RTCIceServer> iceServers) =>
      lastIceServers = iceServers;

  @override
  void restartIce(ms.IceParameters iceParameters) => iceRestarts++;

  @override
  Future<void> close() async => closed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class FakeProducer implements ms.Producer {
  FakeProducer({required this.id, required this.tag, this.encodings = const []});

  @override
  final String id;

  final String tag;
  final List<ms.RtpEncodingParameters> encodings;

  @override
  bool closed = false;
  bool isPaused = false;

  /// Every layer the server steered us to, so the debounce can be asserted on.
  final List<int> maxSpatialLayers = [];

  @override
  void pause() => isPaused = true;

  @override
  void resume() => isPaused = false;

  @override
  void close() => closed = true;

  @override
  Future<void> setMaxSpatialLayer(int spatialLayer) async =>
      maxSpatialLayers.add(spatialLayer);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class FakeConsumer implements ms.Consumer {
  FakeConsumer({
    required this.id,
    required this.producerId,
    required this.appData,
  });

  @override
  final String id;

  @override
  final String producerId;

  @override
  final Map<String, dynamic> appData;

  @override
  final MediaStream stream = FakeStream();

  @override
  bool closed = false;

  bool _paused = false;

  @override
  bool get paused => _paused;

  @override
  void pause() => _paused = true;

  @override
  void resume() => _paused = false;

  @override
  Future<void> close() async => closed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// A stream with one track of each kind and nothing native underneath.
class FakeStream implements MediaStream {
  FakeStream({this.audio = true, this.video = true});

  final bool audio;
  final bool video;

  @override
  String get id => 'fake-stream';

  @override
  List<MediaStreamTrack> getAudioTracks() =>
      audio ? [FakeTrack('audio')] : const [];

  @override
  List<MediaStreamTrack> getVideoTracks() =>
      video ? [FakeTrack('video')] : const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class FakeTrack implements MediaStreamTrack {
  FakeTrack(this.kind);

  @override
  final String kind;

  @override
  String get id => 'fake-$kind';

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// The `callback`/`errback` pair mediasoup hands its listeners.
class _Completer {
  final _completer = Completer<Object?>();

  Future<Object?> get future => _completer.future;

  void callback([Object? value]) {
    if (!_completer.isCompleted) _completer.complete(value);
  }

  void errback([Object? error]) {
    if (!_completer.isCompleted) {
      _completer.completeError(error ?? StateError('produce refused'));
    }
  }
}
