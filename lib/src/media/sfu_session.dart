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

/// Somebody else's media, as this client currently holds it.
///
/// [paused] is *their* mute, not ours: the track is still there and still
/// subscribed, and it will start again without renegotiating. A UI that drew a
/// paused person as absent would make every mute look like a disconnection.
class RemoteMedia {
  const RemoteMedia({
    required this.srcId,
    required this.streams,
    required this.paused,
  });

  /// Their `UserAccount.id` — the media plane's identity, not `SpaceUser.id`.
  final String srcId;
  final Map<SfuTag, MediaStream> streams;
  final Set<SfuTag> paused;

  MediaStream? get audio => streams[SfuTag.audio];
  MediaStream? get video => streams[SfuTag.video];
  MediaStream? get screen => streams[SfuTag.screen];

  bool get hasVideo => video != null && !paused.contains(SfuTag.video);
}

/// Gather's tag word, or null if it is one we do not model.
///
/// Null rather than a default: a tag we have never seen is a protocol change,
/// and quietly filing it under `audio` would play somebody's screen share into
/// the earpiece.
SfuTag? _tagOf(Object? wire) => switch (wire) {
      'audio' => SfuTag.audio,
      'video' => SfuTag.video,
      'screen' => SfuTag.screen,
      _ => null,
    };

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

  /// Every node we hold a socket to, keyed by url — **including** our own.
  ///
  /// A pool rather than a connection, because peers are spread across nodes:
  /// `get-addr` is asked per *person*, not once at startup, and two colleagues in
  /// the same conversation can easily answer with two different hosts. Modelling
  /// this as one media connection would work in a small space and quietly lose
  /// half the room in a large one.
  final Map<String, SfuSignalling> _nodes = {};

  /// Which node each peer's media is on, learned from the router.
  final Map<String, String> _peerNode = {};

  /// One receive transport per node, built on first use.
  final Map<String, ms.Transport> _recvTransports = {};

  /// Live consumers, keyed `srcId|tag`.
  final Map<String, ms.Consumer> _consumers = {};

  /// What the server says each peer is publishing — the desired state that
  /// [_reconcile] steers towards. Replaced wholesale per `consume-try`, never
  /// merged: the announcement is full-state, and merging would leave a track
  /// alive after somebody stopped sending it.
  final Map<String, Map<SfuTag, String>> _announced = {};

  /// Peers we have asked the server to send us.
  final Set<String> _subscribed = {};

  final _remotes = StreamController<List<RemoteMedia>>.broadcast();
  final _notifications = StreamController<SfuNotification>.broadcast();
  final List<StreamSubscription<SfuNotification>> _nodeSubscriptions = [];

  /// Everybody we are currently receiving, most recently changed last.
  List<RemoteMedia> get remotes => _remoteList();

  /// Fires whenever [remotes] changes — a track arriving, going, or being paused.
  Stream<List<RemoteMedia>> get remoteChanges => _remotes.stream;

  /// Whether we are ready to publish. False until [start] has run through.
  bool get ready => _device?.loaded == true && _node != null;

  String? get sfuAddr => _sfuAddr;

  /// Everything every node says unprompted, merged.
  ///
  /// Merged rather than per-node because the caller cares that a colleague's
  /// camera came on, not which host told us.
  Stream<SfuNotification> get notifications => _notifications.stream;

  /// Steps 1–4: assigned, connected, and capable.
  Future<void> start() async {
    final router = _open(_routerUrl, null);
    _router = router;
    await router.start();

    // The router answers `{addrFound}` in the ack and the address itself in a
    // *separate* `addrs` event, so the ack alone is not enough to proceed on.
    // Listening has to start *before* the question goes out, or a fast answer
    // arrives while nobody is at the door.
    final addrs = _firstNotification(
      router,
      'addrs',
      where: (n) => n.data['srcId'] == _srcId,
    );
    final found = await router.sendWithResponse(
      'get-addr',
      {'srcId': _srcId, 'srcStreamId': _spaceId},
    );
    if (found['addrFound'] == false) {
      throw const SfuException('the router has no SFU assigned to us yet');
    }

    final addr = (await addrs)?.data['sfuAddr'];
    if (addr is! String || addr.isEmpty) {
      throw const SfuException('the router never sent us an address');
    }
    _sfuAddr = addr;
    _log('sfu: assigned $addr');

    final node = await _nodeAt(addr);
    _node = node;

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

    // Re-send the allow list to the node we just connected to. The client does
    // exactly this in `playerConnectedSFU` — `Object.keys(this.allowed).forEach(
    // e => r.allow(e))` — because the list lives on the *node*, so a list built
    // before this socket existed means nothing to it.
    for (final dstId in _allowed) {
      node.emit('consume-allow', {'dstId': dstId, 'allowed': true});
    }

    // Gather's own constants: credentials last 86400s and it refreshes every
    // 14400. A phone call rarely runs four hours, so this is insurance rather
    // than routine — but the failure it insures against is a relay silently
    // expiring mid-call, which looks exactly like the other person going quiet.
    _turnTimer?.cancel();
    _turnTimer = Timer.periodic(
      const Duration(seconds: 14400),
      (_) => unawaited(refreshTurn()),
    );
  }

  Timer? _turnTimer;

  /// A connected socket to [url], reused if we already hold one.
  ///
  /// Every node is watched the same way, so a `consume-try` about a colleague on
  /// a far node reaches the same reconciliation as one about a colleague on ours.
  Future<SfuSignalling> _nodeAt(String url) async {
    final existing = _nodes[url];
    if (existing != null) return existing;

    final node = _open(url, null);
    _nodes[url] = node;
    _nodeSubscriptions.add(node.notifications.listen(_onNotification));
    try {
      await node.start();
    } on Object {
      // Do not leave a half-open node in the pool: the next caller would reuse it
      // and get `not connected` rather than a fresh attempt.
      _nodes.remove(url);
      await node.dispose();
      rethrow;
    }
    return node;
  }

  /// The router's answer to "where is this person's media?".
  ///
  /// Cached per peer. The router will answer again on `reassign`, which is the
  /// event that invalidates it.
  Future<String?> _nodeUrlFor(String srcId) async {
    final cached = _peerNode[srcId];
    if (cached != null) return cached;

    final router = _router;
    if (router == null) return null;

    final addrs = _firstNotification(
      router,
      'addrs',
      where: (n) => n.data['srcId'] == srcId,
    );
    await router.sendWithResponse(
      'get-addr',
      {'srcId': srcId, 'srcStreamId': _spaceId},
    );
    final addr = (await addrs)?.data['sfuAddr'];
    if (addr is! String || addr.isEmpty) return null;
    return _peerNode[srcId] = addr;
  }

  /// The next notification matching [name], or **null** if it never comes.
  ///
  /// Null rather than an error, deliberately. This future is created *before* the
  /// request that provokes the reply — it has to be, or a fast answer lands before
  /// anyone is listening — which means there is a window where it exists and
  /// nothing is awaiting it yet. A future that completes with an error inside that
  /// window is reported as an unhandled exception and takes the isolate's error
  /// handler with it, which is exactly what happened here: `Stream.firstWhere` on
  /// a socket that closed threw `Bad state: No element` out of a microtask, from
  /// code whose own `try` had already moved on. Completing with null cannot do
  /// that, and it puts the decision about what the absence *means* at the call
  /// site, where the wording of the error belongs.
  Future<SfuNotification?> _firstNotification(
    SfuSignalling signalling,
    String name, {
    bool Function(SfuNotification)? where,
    Duration timeout = const Duration(seconds: 10),
  }) {
    final completer = Completer<SfuNotification?>();
    late final StreamSubscription<SfuNotification> subscription;

    void settle(SfuNotification? value) {
      if (completer.isCompleted) return;
      completer.complete(value);
      subscription.cancel();
    }

    final timer = Timer(timeout, () => settle(null));
    subscription = signalling.notifications.listen(
      (n) {
        if (n.name == name && (where == null || where(n))) settle(n);
      },
      // The socket dying is an answer too, and a faster one than the timeout.
      onDone: () => settle(null),
      onError: (Object _) => settle(null),
    );

    return completer.future.whenComplete(timer.cancel);
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
        encodings: tag == SfuTag.audio
            ? const <ms.RtpEncodingParameters>[]
            : _videoEncodings,
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

  /// Who may consume our streams — **the gate on anybody seeing us at all.**
  ///
  /// This is not a nicety. In the desktop client `PeerManager.allow(player)`
  /// keys on `userAccountId`, and its counterpart `_disallowImpl` stops
  /// producing entirely once nobody is allowed:
  ///
  /// ```js
  /// allow(A){ const e = A.userAccountId; … this.currentStrategy.allow(e);
  ///           if (wasProducingUnnecessary) { /* start producing */ } }
  /// ```
  ///
  /// So a client that publishes video without allowing anybody is publishing
  /// into a void: colleagues get `consume-not-allowed` and the little circle
  /// never appears over your head.
  ///
  /// The allow list is **wider than the cluster** — the client drives it from
  /// `inRangeSpaceUserIds`, everyone within twelve tiles on the same floor. Being
  /// in range is what makes your camera visible over your avatar; being in a
  /// cluster is having joined the conversation. Confusing the two means your
  /// video only ever reaches people you are already talking to, which is not what
  /// anybody standing next to you sees in Gather.
  final Set<String> _allowed = {};

  /// Everybody currently permitted to consume us.
  Set<String> get allowed => Set.unmodifiable(_allowed);

  /// Reconcile the whole allow list, as the client does — diffed, not re-sent.
  void setAllowed(Set<String> srcIds) {
    final wanted = srcIds.where((id) => id != _srcId).toSet();
    for (final gone in _allowed.difference(wanted).toList()) {
      allow(gone, allowed: false);
    }
    for (final added in wanted.difference(_allowed).toList()) {
      allow(added, allowed: true);
    }
  }

  void allow(String dstId, {required bool allowed}) {
    if (dstId == _srcId) return;
    if (allowed ? !_allowed.add(dstId) : !_allowed.remove(dstId)) return;
    _node?.emit('consume-allow', {'dstId': dstId, 'allowed': allowed});
  }

  // ---------------------------------------------------------------------------
  // Receiving
  // ---------------------------------------------------------------------------

  /// Ask the server to start sending us [srcId]'s media.
  ///
  /// This does not itself create a consumer. It puts us on the list, and the
  /// server answers with `consume-try` carrying everything they publish — now and
  /// on every later change. [_reconcile] does the rest.
  Future<void> subscribe(String srcId) async {
    if (srcId == _srcId || _subscribed.contains(srcId)) return;
    _subscribed.add(srcId);

    // Grant before asking. Consumption is reciprocal, and a colleague whose
    // client is already asking for us should not have to wait for a second
    // round trip because we granted them late.
    allow(srcId, allowed: true);

    final url = await _nodeUrlFor(srcId);
    if (url == null) {
      _log('sfu: the router does not know where $srcId is');
      _subscribed.remove(srcId);
      return;
    }

    final node = await _nodeAt(url);
    await node.sendWithResponse('consume-request', {
      'srcId': srcId,
      'srcStreamId': _spaceId,
      'requested': true,
    });
    _log('sfu: subscribed to $srcId on $url');
  }

  /// Stop receiving [srcId], and stop the server sending.
  ///
  /// Both halves matter: closing the consumers alone leaves the SFU forwarding
  /// packets we drop on the floor, which is somebody's battery.
  Future<void> unsubscribe(String srcId) async {
    if (!_subscribed.remove(srcId)) return;

    final url = _peerNode.remove(srcId);
    final node = url == null ? null : _nodes[url];
    node?.emit('consume-request', {
      'srcId': srcId,
      'srcStreamId': _spaceId,
      'requested': false,
    });
    _router?.emit('unsubscribe', {'srcId': srcId, 'srcStreamId': _spaceId});
    allow(srcId, allowed: false);

    _announced.remove(srcId);
    for (final tag in SfuTag.values) {
      _closeConsumer(srcId, tag);
    }
    _publishRemotes();
  }

  /// The set of people we want to hear, reconciled in one call.
  ///
  /// Callers hand over the whole desired membership rather than deltas — the
  /// cluster arrives that way, and diffing here is the only place that can be
  /// sure a peer who vanished between two rosters is actually let go.
  Future<void> setSubscriptions(Set<String> srcIds) async {
    final wanted = srcIds.where((id) => id != _srcId).toSet();
    for (final gone in _subscribed.difference(wanted).toList()) {
      await unsubscribe(gone);
    }
    for (final added in wanted.difference(_subscribed).toList()) {
      await subscribe(added);
    }
  }

  void _onNotification(SfuNotification n) {
    if (!_notifications.isClosed) _notifications.add(n);

    switch (n.name) {
      // The full-state announcement of one peer's producers. Not a delta: an
      // empty map means they publish nothing, and treating it as "no news" is
      // what would leave a muted colleague apparently still talking.
      case 'consume-try':
        final srcId = n.data['srcId'];
        if (srcId is! String) return;
        final map = _map(n.data['producerIdMap']);
        _announced[srcId] = {
          for (final entry in map.entries)
            if (_tagOf(entry.key) case final tag?)
              if (entry.value is String) tag: entry.value as String,
        };
        unawaited(_reconcile(srcId));

      case 'consume-close':
        final srcId = n.data['srcId'];
        final tag = _tagOf(n.data['tag']);
        if (srcId is! String || tag == null) return;
        _announced[srcId]?.remove(tag);
        if (_closeConsumer(srcId, tag)) _publishRemotes();

      // Somebody muted. The consumer stays — this is a pause, not a departure —
      // and the UI needs to know so it can draw the crossed-out microphone
      // rather than a person who has simply gone silent.
      case 'producer-paused':
      case 'producer-resumed':
        final srcId = n.data['srcId'];
        final tag = _tagOf(n.data['tag']);
        if (srcId is! String || tag == null) return;
        final consumer = _consumers['$srcId|${tag.wire}'];
        if (consumer == null) return;
        if (n.name == 'producer-paused') {
          consumer.pause();
        } else {
          consumer.resume();
        }
        _publishRemotes();

      // The server steering our *sending* quality. This is the other half of
      // declaring three encodings and activating one: without it we would encode
      // the bottom layer forever and a colleague looking at us full-screen would
      // never get more than a quarter-resolution picture.
      //
      // Transcribed from the client, which does exactly this and no more —
      // `_onProducerSpatialLayer({kind, layer})` → `setMaxSpatialLayer(layer)`,
      // debounced, errors logged rather than raised. mediasoup flips `active`
      // itself; there is no manual encoding surgery to do.
      case 'set-max-spatial-layer':
        if (n.data['kind'] != 'video') return;
        final layer = n.data['layer'];
        if (layer is! num) return;
        unawaited(_setMaxSpatialLayer(layer.toInt()));

      // The SFU has noticed two connections claiming to be us — this phone and
      // the desktop client, which share one `UserAccount` and therefore one
      // `srcId`.
      //
      // **The phone keeps the call.** That is a product decision: you picked up
      // your phone, so the phone is where you are. It is also the only half of
      // this we control — there is no "drop my other client" anywhere in the
      // measured method set, so the desktop stopping is something the *server*
      // does, not something we can ask for.
      //
      // Gather's own client answers `double-connected` with `reload()`, which
      // re-runs `_reconcileProducedTracks` and republishes. Two clients both
      // doing that would take turns knocking each other off forever, so this
      // deliberately does **not** reload: it holds what it has, and counts. If
      // the notice keeps arriving, the two ends are flapping, and at that point
      // the honest move is to stop and say so rather than keep fighting a fight
      // nobody can win from here.
      case 'double-connected':
        _doubleConnected++;
        _log('sfu: another client of ours is on this call '
            '(notice $_doubleConnected)');
        if (_doubleConnected >= _flappingAfter) {
          _log('sfu: standing down — the two clients are fighting');
          unawaited(_standDown());
        }

      // The node is being drained. Everything on it has to move, and the router
      // is the only thing that knows where to.
      case 'cordon-sfu':
      case 'reassign':
        unawaited(_reassign(n.data['sfuAddr']));
    }
  }

  /// How many `double-connected` notices we have taken before giving up.
  ///
  /// Three, because one is the expected cost of taking the call over — the
  /// desktop was here first and the server says so — and a third means the two
  /// ends are swapping it back and forth rather than settling.
  static const _flappingAfter = 3;

  int _doubleConnected = 0;

  /// How many times the SFU has told us another client of ours is here.
  ///
  /// Nonzero is normal during a takeover. [displaced] is the state that matters.
  int get doubleConnectedNotices => _doubleConnected;

  /// Whether we stopped publishing because the two clients could not settle.
  ///
  /// Sticky for the session. Retrying would restart the fight this exists to
  /// end, so the way back is a deliberate new session — the person quitting
  /// Gather on their Mac and tapping unmute again.
  bool get displaced => _displaced;
  bool _displaced = false;

  /// Give up publishing, keep receiving.
  ///
  /// Half a call is much better than none here: the desktop is carrying our
  /// microphone and camera, so the useful thing this phone can still do is show
  /// us the room. Tearing the whole session down would take that away too.
  Future<void> _standDown() async {
    if (_displaced) return;
    _displaced = true;
    for (final tag in _producers.keys.toList()) {
      await unpublish(tag);
    }
    _publishRemotes();
  }

  /// Fresh TURN credentials, and an ICE restart to use them.
  ///
  /// Transcribed from the client: `restart-ice` answers with `{iceParameters,
  /// iceServers}`, the servers go in first and only when non-empty, then the
  /// restart. There is no REST endpoint for this — rotation happens here or not
  /// at all, and when it does not, a call that outlives the credential loses its
  /// relay and goes silent for exactly the people who needed the relay.
  Future<void> refreshTurn() async {
    final node = _node;
    if (node == null) return;
    for (final transport in <ms.Transport>{
      ?_sendTransport,
      ..._recvTransports.values,
    }) {
      try {
        final reply = await node.sendWithResponse('restart-ice', {
          'transportId': transport.id,
          'iceTransportRequestOptions': <String, Object?>{},
        });
        final servers = _iceServers(reply['iceServers']);
        if (servers.isNotEmpty) transport.updateIceServers(servers);
        final ice = reply['iceParameters'];
        if (ice is Map) {
          transport.restartIce(ms.IceParameters.fromMap(_map(ice)));
        }
      } on Object catch (error) {
        _log('sfu: refreshing TURN on ${transport.id} failed: $error');
      }
    }
  }

  Future<void> _setMaxSpatialLayer(int layer) async {
    final producer = _producers[SfuTag.video];
    if (producer == null) return;
    try {
      await producer.setMaxSpatialLayer(layer);
      _log('sfu: sending video up to layer $layer');
    } on Object catch (error) {
      // Logged, not raised. A failed quality change is a worse picture; letting
      // it escape would take the call down over it.
      _log('sfu: could not set the max spatial layer: $error');
    }
  }

  /// One reconciliation per peer at a time.
  ///
  /// `consume-try` arrives whenever anything about a peer changes, and two of
  /// them in quick succession — muting and unmuting, or a camera coming on right
  /// after a join — would otherwise run two reconciliations concurrently. Both
  /// would look at the same empty slot, both would decide to consume, and the
  /// peer would end up with two consumers on one tag: doubled audio, and only one
  /// of them reachable to close. Serialising per peer keeps the check and the
  /// creation in the same turn.
  final Map<String, Future<void>> _reconciling = {};

  Future<void> _reconcile(String srcId) {
    final queued = (_reconciling[srcId] ?? Future<void>.value())
        .then((_) => _reconcileNow(srcId));
    _reconciling[srcId] = queued.then((_) {}, onError: (_) {});
    return queued;
  }

  /// Bring the consumers for one peer in line with what the server announced.
  ///
  /// Reconciliation rather than event handling, because `consume-try` is
  /// full-state: whatever is in the map should exist, whatever is not should not,
  /// and arriving at that from any starting point is the only behaviour that
  /// survives a missed message or a reconnect.
  Future<void> _reconcileNow(String srcId) async {
    final announced = _announced[srcId] ?? const <SfuTag, String>{};
    var changed = false;

    for (final tag in SfuTag.values) {
      final key = '$srcId|${tag.wire}';
      final want = announced[tag];
      final have = _consumers[key];

      if (want == null) {
        if (_closeConsumer(srcId, tag)) changed = true;
        continue;
      }
      // A producer id that changed under us is a *new* stream on the same tag —
      // they turned the camera off and on. The old consumer is pointed at
      // something that no longer exists.
      if (have != null && have.producerId != want) {
        _closeConsumer(srcId, tag);
        changed = true;
      } else if (have != null) {
        continue;
      }

      try {
        await _consume(srcId, tag);
        changed = true;
      } on Object catch (error) {
        _log('sfu: consuming ${tag.wire} from $srcId failed: $error');
      }
    }

    if (changed) _publishRemotes();
  }

  Future<void> _consume(String srcId, SfuTag tag) async {
    final device = _device;
    if (device == null) throw const SfuException('consume before start');

    final url = await _nodeUrlFor(srcId);
    if (url == null) throw SfuException('no node known for $srcId');
    final node = await _nodeAt(url);
    final transport = await _recvTransportOn(url);

    final reply = await node.sendWithResponse('consume', {
      'transportId': transport.id,
      'srcId': srcId,
      'srcStreamId': _spaceId,
      'tag': tag.wire,
      'rtpCapabilities': device.rtpCapabilities.toMap(),
    });

    final id = reply['id'];
    final producerId = reply['producerId'];
    if (id is! String || producerId is! String) {
      throw const SfuException('consume returned no consumer');
    }

    final key = '$srcId|${tag.wire}';
    final completer = Completer<ms.Consumer>();
    _pendingConsumers[key] = completer;

    try {
      transport.consume(
        id: id,
        producerId: producerId,
        peerId: srcId,
        kind: tag == SfuTag.audio
            ? RTCRtpMediaType.RTCRtpMediaTypeAudio
            : RTCRtpMediaType.RTCRtpMediaTypeVideo,
        rtpParameters:
            ms.RtpParameters.fromMap(_map(reply['rtpParameters'])),
        appData: {'srcId': srcId, 'tag': tag.wire},
        accept: () {},
      );

      final consumer = await completer.future.timeout(
        const Duration(seconds: 20),
        onTimeout: () =>
            throw SfuException('consuming ${tag.wire} from $srcId timed out'),
      );
      _consumers[key] = consumer;

      // Unusual, and easy to miss: the SFU wants telling that the consumer was
      // actually built. Measured going *back* to the server after its own ack.
      node.emit('consume-created', {
        'srcId': srcId,
        'srcStreamId': _spaceId,
        'tag': tag.wire,
        'consumerId': consumer.id,
      });

      // Consumers arrive paused. Nothing flows until this.
      if (reply['producerPaused'] != true) {
        node.emit('consume-resume', {
          'srcId': srcId,
          'srcStreamId': _spaceId,
          'tag': tag.wire,
          'consumerId': consumer.id,
        });
        consumer.resume();
      }
      _log('sfu: consuming ${tag.wire} from $srcId');
    } finally {
      _pendingConsumers.remove(key);
    }
  }

  final Map<String, Completer<ms.Consumer>> _pendingConsumers = {};

  /// Where the transport delivers a finished Consumer, matched by the `appData`
  /// we sent into `consume` — several can be in flight at once, so unlike the
  /// send side this cannot use a single slot.
  void _onConsumer(ms.Consumer consumer, [Object? accept]) {
    final srcId = consumer.appData['srcId'];
    final tag = consumer.appData['tag'];
    final pending = _pendingConsumers['$srcId|$tag'];
    if (pending != null && !pending.isCompleted) pending.complete(consumer);
    if (accept is Function) accept();
  }

  Future<ms.Transport> _recvTransportOn(String url) async {
    final existing = _recvTransports[url];
    if (existing != null) return existing;

    final device = _device;
    final node = await _nodeAt(url);
    if (device == null) throw const SfuException('consume before start');

    final reply = await node.sendWithResponse(
      'transport-create',
      {'direction': 'recv', 'iceTransportRequestOptions': <String, Object?>{}},
    );

    final transport = device.createRecvTransport(
      id: reply['id'] as String,
      iceParameters: ms.IceParameters.fromMap(_map(reply['iceParameters'])),
      iceCandidates: [
        for (final c in (reply['iceCandidates'] as List? ?? const []))
          ms.IceCandidate.fromMap(_map(c)),
      ],
      dtlsParameters: ms.DtlsParameters.fromMap(_map(reply['dtlsParameters'])),
      iceServers: _iceServers(reply['iceServers']),
      iceTransportPolicy: reply['iceTransportPolicy'] == 'relay'
          ? RTCIceTransportPolicy.relay
          : RTCIceTransportPolicy.all,
      appData: _map(reply['appData']),
      consumerCallback: _onConsumer,
    );

    transport.on('connect', (Map data) async {
      try {
        await node.sendWithResponse('transport-connect', {
          'transportId': transport.id,
          'dtlsParameters': (data['dtlsParameters'] as ms.DtlsParameters).toMap(),
        });
        data['callback']();
      } on Object catch (error) {
        _log('sfu: recv transport-connect failed: $error');
        data['errback'](error);
      }
    });

    return _recvTransports[url] = transport;
  }

  bool _closeConsumer(String srcId, SfuTag tag) {
    final consumer = _consumers.remove('$srcId|${tag.wire}');
    if (consumer == null) return false;
    consumer.close();
    return true;
  }

  /// The node we were on is being drained; find out where we go instead.
  Future<void> _reassign(Object? sfuAddr) async {
    final leaving = sfuAddr is String && sfuAddr.isNotEmpty ? sfuAddr : _sfuAddr;
    _log('sfu: $leaving is being drained');

    // Everything we knew about locations is now suspect, including our own.
    _peerNode.removeWhere((_, url) => url == leaving);
    if (leaving == _sfuAddr) {
      // Our own producers live on that node. Rebuilding them is the caller's
      // business — it owns the tracks — so say so rather than half-heal.
      _log('sfu: our own node was drained; the session needs restarting');
    }
    for (final srcId in _subscribed.toList()) {
      unawaited(_reconcile(srcId));
    }
  }

  List<RemoteMedia> _remoteList() {
    final byPeer = <String, Map<SfuTag, ms.Consumer>>{};
    for (final entry in _consumers.entries) {
      final parts = entry.key.split('|');
      final tag = _tagOf(parts.last);
      if (tag == null) continue;
      (byPeer[parts.first] ??= {})[tag] = entry.value;
    }
    return [
      for (final entry in byPeer.entries)
        RemoteMedia(
          srcId: entry.key,
          streams: {
            for (final t in entry.value.entries) t.key: t.value.stream,
          },
          paused: {
            for (final t in entry.value.entries)
              if (t.value.paused) t.key,
          },
        ),
    ];
  }

  void _publishRemotes() {
    if (!_remotes.isClosed) _remotes.add(_remoteList());
  }

  Future<void> stop() async {
    _turnTimer?.cancel();
    _turnTimer = null;
    for (final tag in _producers.keys.toList()) {
      await unpublish(tag);
    }
    for (final consumer in _consumers.values) {
      consumer.close();
    }
    _consumers.clear();
    _pendingConsumers.clear();
    _reconciling.clear();
    _announced.clear();
    _subscribed.clear();
    _peerNode.clear();

    _sendTransport?.close();
    _sendTransport = null;
    for (final transport in _recvTransports.values) {
      transport.close();
    }
    _recvTransports.clear();
    _device = null;

    // Cancel before disposing, or a node's closing notifications arrive at a
    // handler that reaches for state we have just cleared.
    for (final subscription in _nodeSubscriptions) {
      await subscription.cancel();
    }
    _nodeSubscriptions.clear();
    for (final node in _nodes.values.toList()) {
      await node.dispose();
    }
    _nodes.clear();
    await _router?.dispose();
    _node = null;
    _router = null;
    _sfuAddr = null;
    _publishRemotes();
  }

  /// Closes everything and releases the streams. The session cannot be restarted.
  Future<void> dispose() async {
    await stop();
    await _remotes.close();
    await _notifications.close();
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

/// The three simulcast layers, transcribed from Gather's own client.
///
/// **Only `r0` is active**, and that is the point. The plan's worry — that three
/// concurrent software VP8 encodes would cook a phone, VP8 having no hardware
/// encoder on Apple silicon — was aimed at the wrong thing: declaring a layer
/// costs nothing, *encoding* one costs, and Gather encodes one at a time. The
/// server flips the others on through `set-max-spatial-layer` when a consumer
/// actually asks for more resolution, and on a phone it mostly never does.
///
/// Declaring all three anyway is what lets somebody on a desktop, looking at you
/// full-screen, get a better picture without a renegotiation. Declaring one would
/// have capped every viewer at a quarter-resolution thumbnail forever.
final _videoEncodings = [
  ms.RtpEncodingParameters(
    rid: 'r0',
    active: true,
    scaleResolutionDownBy: 4,
    maxBitrate: 120000,
    maxFramerate: 18,
    scalabilityMode: 'L1T2',
  ),
  ms.RtpEncodingParameters(
    rid: 'r1',
    active: false,
    scaleResolutionDownBy: 2,
    maxBitrate: 350000,
    maxFramerate: 24,
    scalabilityMode: 'L1T2',
  ),
  ms.RtpEncodingParameters(
    rid: 'r2',
    active: false,
    scaleResolutionDownBy: 1,
    maxBitrate: 1500000,
    maxFramerate: 24,
    scalabilityMode: 'L1T2',
  ),
];

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
