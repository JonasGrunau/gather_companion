/// Push registration, which is the only thing the app still asks the computer for.
///
/// Worth pinning because every failure here is silent by construction. The phone
/// registers, or does not; the bridge sends, or does not; FCM answers 200 either
/// way. When this went wrong in August 2026 it went wrong for a fortnight without
/// a single error anywhere — the app had lost its bridge address in a reinstall,
/// so it never handed over a token, and the bridge went on pushing to the token
/// from the install before. The fix was not a bug in any one line; it was that the
/// outcome of this call was thrown away, so nothing could tell the difference
/// between "registered fine" and "never tried".
///
/// So these tests are all about the *outcome*, one case per thing that goes wrong,
/// because each of the six has a different repair in a different place.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather_companion/src/push.dart';
import 'package:gather_companion/src/settings.dart';

void main() {
  const settings = BridgeSettings(host: '10.0.0.9', port: 7799, token: 'bridge-token');

  /// A bridge that records what it was told and answers how it is asked to.
  late _FakeBridge bridge;

  setUp(() => bridge = _FakeBridge());

  PushRegistrar registrar({
    String? apns = 'apns-device-token',
    String? fcm = 'fcm-token',
    AuthorizationStatus status = AuthorizationStatus.authorized,
  }) =>
      PushRegistrar(
        messaging: _FakeMessaging(apns: apns, fcm: fcm, status: status),
        httpClient: bridge.client,
      );

  test('no bridge address means nothing is even attempted', () async {
    // The state an app reinstall leaves behind, and the one that used to be
    // rendered as "Unreachable". Nothing is wrong with the network; there is
    // simply nowhere to send a token.
    final result = await registrar().register(BridgeSettings.empty);

    expect(result.reach, PushReach.unpaired);
    expect(bridge.requests, isEmpty, reason: 'there is no host to post to');
  });

  test('a refused permission is a decision, not a failure', () async {
    final result = await registrar(status: AuthorizationStatus.denied).register(settings);

    expect(result.reach, PushReach.denied);
    expect(bridge.requests, isEmpty);
  });

  test('APNs never answering is reported as such, not as an unreachable Mac', () async {
    // A simulator, or a build signed without the push entitlement. This is the
    // one that wastes an afternoon on the computer when the computer is fine.
    final result = await registrar(apns: null).register(settings);

    expect(result.reach, PushReach.noToken);
    expect(bridge.requests, isEmpty, reason: 'a token APNs never issued is not worth posting');
  });

  test('a bridge that answers 200 and says it can send is armed', () async {
    bridge.respond(200, {'ok': true, 'devices': 1, 'sending': true});

    final result = await registrar().register(settings);

    expect(result.reach, PushReach.armed);
    expect(result.isArmed, isTrue);
    expect(result.at, isNotNull, reason: 'the card wants to say when');
    expect(bridge.requests.single.path, '/push/register');
    expect(bridge.requests.single.query['token'], 'bridge-token');
    expect(bridge.requests.single.body['token'], 'fcm-token');
    expect(bridge.requests.single.body['platform'], Platform.isIOS ? 'ios' : 'other');
  });

  test('a reachable bridge with no FCM credential is its own answer', () async {
    // Held apart from `unreachable` because it is fixed on the computer with
    // `gather-app-bridge push setup`, and no amount of networking helps.
    bridge.respond(200, {'ok': true, 'devices': 1, 'sending': false});

    expect((await registrar().register(settings)).reach, PushReach.noCredential);
  });

  test('an older bridge that cannot report sending is assumed able', () async {
    // `sending` arrived with this change. Telling everyone on a daemon that
    // predates it that push is broken would be a worse lie than the one removed.
    bridge.respond(200, {'ok': true, 'devices': 1});

    expect((await registrar().register(settings)).reach, PushReach.armed);
  });

  test('a bridge that refuses the token is unreachable, not armed', () async {
    bridge.respond(400, {'ok': false});

    expect((await registrar().register(settings)).reach, PushReach.unreachable);
  });

  test('a Mac that is asleep is unreachable and does not throw', () async {
    // The normal state — the phone is on cellular, or the lid is shut. It must
    // never become a launch crash, and it must never read as armed.
    bridge.fail(const SocketException('no route to host'));

    expect((await registrar().register(settings)).reach, PushReach.unreachable);
  });

  test('the install id is sent, so the bridge can replace our old token', () async {
    // Without it the bridge keys on the FCM token, and a reinstall — which mints a
    // new one — leaves the dead token in the list absorbing every push.
    bridge.respond(200, {'ok': true, 'devices': 1, 'sending': true});

    await registrar().register(settings, installId: 'install-7');

    expect(bridge.requests.single.body['installId'], 'install-7');
  });

  test('re-registering re-posts, because the post is the reachability check', () async {
    // The FCM token is fetched once and cached — a second five-second APNs wait on
    // every resume would be its own bug — but the POST has to happen again, or the
    // card could never notice the Mac coming back.
    bridge.respond(200, {'ok': true, 'devices': 1, 'sending': true});
    final push = registrar();

    expect((await push.register(settings)).reach, PushReach.armed);
    bridge.fail(const SocketException('the Mac went to sleep'));
    expect((await push.register(settings)).reach, PushReach.unreachable);
    bridge.respond(200, {'ok': true, 'devices': 1, 'sending': true});
    expect((await push.register(settings)).reach, PushReach.armed);

    expect(bridge.attempts, 3, reason: 'every call has to try, or the card goes stale');
    expect(bridge.requests.length, 2, reason: 'the sleeping Mac never received one');
  });

  test('two identical outcomes compare equal, so the UI does not churn', () async {
    // `AppState` only notifies when this changes, and a resume that finds
    // everything as it was should repaint nothing.
    expect(const PushRegistration(PushReach.armed), const PushRegistration(PushReach.armed));
    expect(
      const PushRegistration(PushReach.armed),
      isNot(const PushRegistration(PushReach.unreachable)),
    );
  });
}

// ---- the fakes ---------------------------------------------------------------

class _Recorded {
  _Recorded(this.path, this.query, this.body);
  final String path;
  final Map<String, String> query;
  final Map<String, Object?> body;
}

/// A stand-in for the daemon on the LAN, driven through the `HttpClient` seam.
class _FakeBridge {
  final requests = <_Recorded>[];

  /// Every POST the app tried, including the ones that never connected. Held apart
  /// from [requests] because a sleeping Mac is an attempt that leaves no request.
  int attempts = 0;
  int _status = 200;
  Object? _payload = const <String, Object?>{};
  Object? _error;

  void respond(int status, Map<String, Object?> payload) {
    _status = status;
    _payload = payload;
    _error = null;
  }

  void fail(Object error) => _error = error;

  HttpClient client() => _FakeHttpClient(this);
}

class _FakeHttpClient implements HttpClient {
  _FakeHttpClient(this._bridge);
  final _FakeBridge _bridge;

  @override
  Future<HttpClientRequest> postUrl(Uri url) async {
    _bridge.attempts++;
    final error = _bridge._error;
    if (error != null) throw error;
    return _FakeRequest(_bridge, url);
  }

  @override
  void close({bool force = false}) {}

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeRequest implements HttpClientRequest {
  _FakeRequest(this._bridge, this._url);
  final _FakeBridge _bridge;
  final Uri _url;
  final _written = StringBuffer();

  @override
  final HttpHeaders headers = _FakeHeaders();

  @override
  void write(Object? object) => _written.write(object);

  @override
  Future<HttpClientResponse> close() async {
    _bridge.requests.add(_Recorded(
      _url.path,
      _url.queryParameters,
      (jsonDecode(_written.toString()) as Map).cast<String, Object?>(),
    ));
    return _FakeResponse(_bridge._status, jsonEncode(_bridge._payload));
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeResponse extends Stream<List<int>> implements HttpClientResponse {
  _FakeResponse(this.statusCode, this._body);

  @override
  final int statusCode;
  final String _body;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      Stream<List<int>>.value(utf8.encode(_body))
          .listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHeaders implements HttpHeaders {
  @override
  ContentType? contentType;

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Firebase, without Firebase. The APNs-then-FCM ordering is the part that
/// matters: `getToken()` on iOS is meaningless until APNs has answered.
class _FakeMessaging implements FirebaseMessaging {
  _FakeMessaging({required this.apns, required this.fcm, required this.status});

  final String? apns;
  final String? fcm;
  final AuthorizationStatus status;

  @override
  Future<NotificationSettings> requestPermission({
    bool alert = true,
    bool announcement = false,
    bool badge = true,
    bool carPlay = false,
    bool criticalAlert = false,
    bool provisional = false,
    bool sound = true,
    bool providesAppNotificationSettings = false,
  }) async =>
      NotificationSettings(
        alert: AppleNotificationSetting.enabled,
        announcement: AppleNotificationSetting.disabled,
        authorizationStatus: status,
        badge: AppleNotificationSetting.enabled,
        carPlay: AppleNotificationSetting.disabled,
        lockScreen: AppleNotificationSetting.enabled,
        notificationCenter: AppleNotificationSetting.enabled,
        showPreviews: AppleShowPreviewSetting.always,
        timeSensitive: AppleNotificationSetting.disabled,
        criticalAlert: AppleNotificationSetting.disabled,
        sound: AppleNotificationSetting.enabled,
        providesAppNotificationSettings: AppleNotificationSetting.disabled,
      );

  @override
  Future<String?> getAPNSToken() async => apns;

  @override
  Future<String?> getToken({String? vapidKey, String? serviceWorkerScriptPath}) async => fcm;

  @override
  Stream<String> get onTokenRefresh => const Stream<String>.empty();

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
