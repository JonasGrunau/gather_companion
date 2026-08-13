/// Publishing to Gather's SFU.
///
/// [SfuSignalling] knows how to say things to the media plane; this knows *what*
/// to say and in what order. The sequence is fixed and each step depends on the
/// last, which is why it reads as a script rather than a state machine:
///
///   1. connect the **router** (`wss://router.v2.gather.town`)
///   2. `get-addr` for our own `srcId` → `addrs {sfuAddr}`
///   3. connect that **node**
///   4. `get-rtp-capabilities` → `Device.load()`
///   5. `transport-create {direction:'send'}` → a mediasoup send transport
///   6. `produce` per track
///
/// Steps 1–4 happen at space join in the desktop client, before any call — they
/// are not call setup, they are being ready for one. Only 5 and 6 wait for
/// somebody to talk to.
///
/// ## `srcId` is the UserAccount id
///
/// Not the `SpaceUser` id. The game plane keys on `SpaceUser`, the media plane on
/// `UserAccount`, and asking the router about the wrong one returns a stream that
/// does not exist — silently, because that is Gather's failure mode. Measured
/// 2026-08-13; see `docs/gather-api.md`.
library;

import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:gather_client/gather_client.dart';
import 'package:mediasfu_mediasoup_client/mediasfu_mediasoup_client.dart' as ms;
// The ICE types, from our own shim rather than from the package: they are not
// exported, and `mediasoup_ice.dart` explains why reaching past the barrel is
// the only way to pass Gather's TURN servers at all.
import 'mediasoup_ice.dart';

/// What Gather calls a stream on a person. `kind` is the codec's idea of the
/// track; `tag` is Gather's idea of what it is *for*, and they differ for screen
/// share, which is `{tag: 'screen', kind: 'video'}`.
enum SfuTag {
  audio,
  video,
  screen;

  String get wire => name;
}

class SfuSession {
  SfuSession({
    required GatherAuth auth,
    required String spaceId,
    required String srcId,
    String routerUrl = gatherSfuRouter,
    SfuSignalling Function(String url, String? sessionId)? openSignalling,
    void Function(String)? log,
    // Assigned the long way round because a named parameter cannot be a private
    // initializing formal — same as `DirectCollector` and `SfuSignalling`.
  })  :
        // ignore: prefer_initializing_formals
        _auth = auth,
        // ignore: prefer_initializing_formals
        _spaceId = spaceId,
        // ignore: prefer_initializing_formals
        _srcId = srcId,
        // ignore: prefer_initializing_formals
        _routerUrl = routerUrl,
        // ignore: prefer_initializing_formals
        _openSignalling = openSignalling,
        _log = log ?? _noop;

  static void _noop(String _) {}

  final GatherAuth _auth;
  final String _spaceId;
  final String _srcId;
  final String _routerUrl;
  final void Function(String) _log;

  /// Test seam: lets a suite hand back a signalling client pointed at a fake.
  final SfuSignalling Function(String url, String? sessionId)? _openSignalling;

  SfuSignalling? _router;
  SfuSignalling? _node;
  ms.Device? _device;
  ms.Transport? _sendTransport;
  final Map<SfuTag, ms.Producer> _producers = {};

  String? _sfuAddr;

  /// Whether we are ready to publish. False until [start] has run through.
  bool get ready => _device?.loaded == true && _node != null;

  String? get sfuAddr => _sfuAddr;

  /// Everything the node says unprompted — `consume-try` and friends. Consuming
  /// is a later phase; exposing the stream now means nothing is being dropped on
  /// the floor in the meantime.
  Stream<SfuNotification> get notifications =>
      _node?.notifications ?? const Stream<SfuNotification>.empty();

  /// Steps 1–4: assigned, connected, and capable.
  Future<void> start() async {
    final router = _open(_routerUrl, null);
    _router = router;
    await router.start();

    // The router answers `{addrFound}` in the ack and the address itself in a
    // *separate* `addrs` event, so the ack alone is not enough to proceed on.
    final addrs = router.notifications.firstWhere(
      (n) => n.name == 'addrs' && n.data['srcId'] == _srcId,
    );
    final found = await router.sendWithResponse(
      'get-addr',
      {'srcId': _srcId, 'srcStreamId': _spaceId},
    );
    if (found['addrFound'] == false) {
      throw const SfuException('the router has no SFU assigned to us yet');
    }

    final addr = (await addrs.timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw const SfuException('the router never sent an address'),
    ))
        .data['sfuAddr'];
    if (addr is! String || addr.isEmpty) {
      throw const SfuException('the router sent no usable sfuAddr');
    }
    _sfuAddr = addr;
    _log('sfu: assigned $addr');

    final node = _open(addr, null);
    _node = node;
    await node.start();

    final caps = await node.sendWithResponse('get-rtp-capabilities');
    final routerCaps = caps['routerRtpCapabilities'];
    if (routerCaps is! Map) {
      throw const SfuException('the SFU returned no routerRtpCapabilities');
    }

    final device = ms.Device();
    await device.load(
      routerRtpCapabilities:
          ms.RtpCapabilities.fromMap(Map<String, dynamic>.from(routerCaps)),
    );
    _device = device;
    _log('sfu: device loaded');
  }

  /// Step 5, on demand: the transport everything we publish rides on.
  ///
  /// Created lazily and once. The desktop client does the same — a transport is
  /// ICE and DTLS, and negotiating it before anyone is listening spends battery
  /// on a conversation that may never happen.
  Future<ms.Transport> _sendTransportOrCreate() async {
    final existing = _sendTransport;
    if (existing != null) return existing;

    final node = _node;
    final device = _device;
    if (node == null || device == null) {
      throw const SfuException('publish before start');
    }

    final reply = await node.sendWithResponse(
      'transport-create',
      {'direction': 'send', 'iceTransportRequestOptions': <String, Object?>{}},
    );

    // NOT `createSendTransportFromMap`: that helper hardcodes `iceServers: []`,
    // which would drop Gather's TURN servers on the floor. The failure mode is
    // the worst kind — fine on a permissive network, silently no media behind a
    // symmetric NAT, and no error either way.
    final transport = device.createSendTransport(
      id: reply['id'] as String,
      iceParameters:
          ms.IceParameters.fromMap(_map(reply['iceParameters'])),
      iceCandidates: [
        for (final c in (reply['iceCandidates'] as List? ?? const []))
          ms.IceCandidate.fromMap(_map(c)),
      ],
      dtlsParameters:
          ms.DtlsParameters.fromMap(_map(reply['dtlsParameters'])),
      iceServers: _iceServers(reply['iceServers']),
      iceTransportPolicy: reply['iceTransportPolicy'] == 'relay'
          ? RTCIceTransportPolicy.relay
          : RTCIceTransportPolicy.all,
      appData: _map(reply['appData']),
      // The transport hands its Producer back here rather than from `produce()`,
      // which returns void.
      producerCallback: _onProducer,
    );

    // mediasoup hands the DTLS handshake back to us: it produces the parameters,
    // we deliver them, and nothing proceeds until `callback()` is called.
    transport.on('connect', (Map data) async {
      try {
        await node.sendWithResponse('transport-connect', {
          'transportId': transport.id,
          'dtlsParameters': (data['dtlsParameters'] as ms.DtlsParameters).toMap(),
        });
        data['callback']();
      } on Object catch (error) {
        _log('sfu: transport-connect failed: $error');
        data['errback'](error);
      }
    });

    // Fired once per `produce()`. The listener's job is to tell the server and
    // hand back the id the server chose — the local Producer is not created until
    // it does.
    transport.on('produce', (Map data) async {
      try {
        final reply = await node.sendWithResponse('produce', {
          'transportId': transport.id,
          'tag': (data['appData'] as Map?)?['tag'] ?? data['kind'],
          'kind': data['kind'],
          'rtpParameters': (data['rtpParameters'] as ms.RtpParameters).toMap(),
        });
        final id = reply['id'];
        if (id is! String) throw const SfuException('produce returned no id');
        data['callback'](id);
      } on Object catch (error) {
        _log('sfu: produce failed: $error');
        data['errback'](error);
      }
    });

    _sendTransport = transport;
    return transport;
  }

  /// Where the transport delivers a finished Producer.
  ///
  /// `produce()` returns void and the object arrives here instead, so [publish]
  /// waits on this rather than on a return value.
  Completer<ms.Producer>? _pendingProducer;

  void _onProducer(ms.Producer producer) {
    final pending = _pendingProducer;
    if (pending != null && !pending.isCompleted) pending.complete(producer);
  }

  /// Step 6: put a track on the wire.
  ///
  /// [stream] is the capture the track came from; mediasoup needs it to build the
  /// sender, not just the track.
  Future<void> publish(
    MediaStreamTrack track,
    MediaStream stream, {
    required SfuTag tag,
  }) async {
    if (_producers.containsKey(tag)) return;
    final transport = await _sendTransportOrCreate();

    // One at a time. The callback is per-transport rather than per-produce, so
    // two overlapping publishes could not be told apart.
    while (_pendingProducer != null) {
      await _pendingProducer!.future.catchError((_) => throw const SfuException('busy'));
    }
    final completer = Completer<ms.Producer>();
    _pendingProducer = completer;

    try {
      transport.produce(
        track: track,
        stream: stream,
        source: tag == SfuTag.screen
            ? 'screen'
            : (tag == SfuTag.audio ? 'mic' : 'webcam'),
        appData: {'tag': tag.wire},
        // Opus with in-band FEC and DTX, matching what the desktop client
        // negotiates — DTX is why a live-but-silent microphone costs almost
        // nothing on the wire.
        codecOptions: tag == SfuTag.audio
            ? ms.ProducerCodecOptions(opusStereo: 0, opusDtx: 1, opusFec: 1)
            : null,
      );

      final producer = await completer.future.timeout(
        const Duration(seconds: 20),
        onTimeout: () => throw SfuException('producing ${tag.wire} timed out'),
      );
      _producers[tag] = producer;
      _log('sfu: publishing ${tag.wire} as ${producer.id}');
    } finally {
      _pendingProducer = null;
    }
  }

  /// Whether we currently have a producer for [tag].
  bool publishing(SfuTag tag) => _producers.containsKey(tag);

  /// Mute, as the wire understands it.
  ///
  /// Muting at the device stops the *sound*; this stops the *stream*, and it is
  /// what makes a colleague's client draw the crossed-out microphone next to your
  /// name. Both are wanted: the device mute is what makes iOS drop its recording
  /// indicator, and this is what makes the mute visible to anyone else.
  ///
  /// The producer is kept rather than closed, so unmuting is a resume rather than
  /// a fresh negotiation. `produce-pause` takes only a tag — the SFU knows which
  /// producer is ours.
  void pause(SfuTag tag) {
    if (!_producers.containsKey(tag)) return;
    _producers[tag]?.pause();
    _node?.emit('produce-pause', {'tag': tag.wire});
  }

  void resume(SfuTag tag) {
    if (!_producers.containsKey(tag)) return;
    _producers[tag]?.resume();
    _node?.emit('produce-resume', {'tag': tag.wire});
  }

  /// Stops publishing one track, telling the server rather than just going quiet.
  Future<void> unpublish(SfuTag tag) async {
    final producer = _producers.remove(tag);
    if (producer == null) return;
    producer.close();
    _node?.emit('produce-close', {'tag': tag.wire});
  }

  /// Who may consume our streams. The reciprocal of `consume-request`.
  void allow(String dstId, {required bool allowed}) =>
      _node?.emit('consume-allow', {'dstId': dstId, 'allowed': allowed});

  Future<void> stop() async {
    for (final tag in _producers.keys.toList()) {
      await unpublish(tag);
    }
    _sendTransport?.close();
    _sendTransport = null;
    _device = null;
    await _node?.dispose();
    await _router?.dispose();
    _node = null;
    _router = null;
    _sfuAddr = null;
  }

  SfuSignalling _open(String url, String? sessionId) =>
      _openSignalling?.call(url, sessionId) ??
      SfuSignalling(
        auth: _auth,
        url: url,
        spaceId: _spaceId,
        sessionId: sessionId,
        log: _log,
      );
}

Map<String, dynamic> _map(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

/// Gather sends TURN credentials with the transport, and refreshes them through
/// `restart-ice` rather than through any REST route.
///
/// `urls` is a string or a list of them per the WebRTC spec, and Gather has been
/// seen sending both shapes, so both are accepted rather than assumed.
List<RTCIceServer> _iceServers(Object? value) {
  if (value is! List) return const [];
  final out = <RTCIceServer>[];
  for (final raw in value) {
    final server = _map(raw);
    final urls = server['urls'];
    out.add(RTCIceServer(
      urls: switch (urls) {
        String s => [s],
        List l => l.whereType<String>().toList(),
        _ => const <String>[],
      },
      username: server['username'] as String? ?? '',
      credential: server['credential'],
      credentialType: RTCIceCredentialType.password,
    ));
  }
  return out;
}
