import 'dart:convert';
import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'settings.dart';

/// How close this phone is to being wakeable while the app is not running.
///
/// Six answers rather than a boolean, because the fixes are different and a phone
/// that says only "no" sends its owner looking in the wrong place. Every one of
/// these was already knowable at the point registration gave up — it was simply
/// thrown away.
enum PushReach {
  /// Nothing has been tried yet. Held apart from [unpaired] because they are
  /// different claims, and the wrong one flashes on screen for the second boot takes
  /// — "no computer paired" is a lie on a phone that is about to register fine.
  pending,

  /// No bridge address stored. Nothing can be handed a token, so nothing can push.
  unpaired,

  /// The person declined notifications. Their call, and the in-app feed still works.
  denied,

  /// APNs never issued a device token: a simulator, or a build without the
  /// entitlement. Registration would be sending something undeliverable.
  noToken,

  /// The bridge did not answer. Usually the computer is asleep, off, or on another
  /// network — a normal state, not a fault.
  unreachable,

  /// The bridge answered, but has no FCM service account, so it cannot send.
  /// A different fix from [unreachable]: `gather-app-bridge push setup`.
  noCredential,

  /// Registered, and the bridge says it is able to send.
  armed,
}

/// The outcome of one registration attempt.
@immutable
class PushRegistration {
  const PushRegistration(this.reach, {this.at});

  /// Before the first attempt. Distinct from [PushReach.unpaired], which is an
  /// answer; this is the absence of one.
  static const unknown = PushRegistration(PushReach.pending);

  final PushReach reach;

  /// When the bridge last accepted our token, by this phone's clock.
  final DateTime? at;

  bool get isArmed => reach == PushReach.armed;

  @override
  bool operator ==(Object other) =>
      other is PushRegistration && other.reach == reach && other.at == at;

  @override
  int get hashCode => Object.hash(reach, at);
}

/// Registers this phone with the bridge so it can be woken while the app is not
/// running.
///
/// This is the half of notifications that survives the app being killed. The
/// local notifications in `notifications.dart` only fire while the WebSocket is
/// alive, which on iOS means "while the app is on screen or briefly after". A
/// wave that arrives at midnight has to come through APNs, and the bridge is
/// what sends it.
///
/// ## Why the APNs token is fetched first
///
/// On Apple platforms `getToken()` returns null — or throws — until APNs has
/// handed the app its device token, which happens asynchronously after
/// `registerForRemoteNotifications`. Asking for the FCM token immediately at
/// launch is the single most common way this ends up silently never working, so
/// [_apnsToken] waits for it with a bounded retry rather than assuming.
///
/// ## Why registering is also the reachability check
///
/// There is no separate probe. `POST /push/register` is idempotent by design on
/// the bridge side and answers with whether it can actually send, so re-posting
/// it is both cheaper and more honest than pinging `/health` and inferring the
/// rest. The FCM token is cached across attempts so a re-post costs one LAN
/// request, not another five-second wait on APNs.
///
/// ## Foreground double-ups
///
/// Not a problem, and deliberately not guarded against. iOS does not display a
/// push while the app is frontmost unless the app asks it to, and we never do.
/// So when the socket is live the local notification is the one you see, and the
/// push is swallowed; when the app is gone the push is the only one there is.
class PushRegistrar {
  PushRegistrar({FirebaseMessaging? messaging, HttpClient Function()? httpClient})
      : _messaging = messaging ?? FirebaseMessaging.instance,
        _newClient = httpClient ?? HttpClient.new;

  final FirebaseMessaging _messaging;
  final HttpClient Function() _newClient;

  /// The FCM token, once APNs has made one possible.
  ///
  /// Cached so that re-registering on every resume does not re-run the bounded
  /// APNs wait. Firebase rotation is handled by [tokenRefreshes], which clears it.
  String? _token;

  /// Asks for notification permission and hands the resulting token to the bridge.
  ///
  /// Safe to call on every connect and every resume. Returns what happened, so the
  /// UI can say something true rather than guessing from whether a host was stored.
  Future<PushRegistration> register(BridgeSettings settings, {String? installId}) async {
    if (!settings.isComplete) return const PushRegistration(PushReach.unpaired);
    try {
      final permission = await _messaging.requestPermission();
      if (permission.authorizationStatus == AuthorizationStatus.denied) {
        return const PushRegistration(PushReach.denied);
      }

      final token = _token ??= await _fcmToken();
      if (token == null) return const PushRegistration(PushReach.noToken);

      return await _send(settings, token, installId);
    } catch (error) {
      // Push is an enhancement. A phone that cannot register still gets the
      // whole feed over the socket, so this must never take the app down with
      // it — a Firebase misconfiguration would otherwise be a launch crash.
      debugPrint('push: could not register — $error');
      return const PushRegistration(PushReach.unreachable);
    }
  }

  /// Keeps registration current when Firebase rotates the token.
  ///
  /// Rotation happens on reinstall, restore from backup, and occasionally on its
  /// own. Without this the bridge would keep pushing to a token that no longer
  /// resolves, and the phone would simply go quiet.
  Stream<String> get tokenRefreshes => _messaging.onTokenRefresh;

  /// Drops the cached token so the next [register] fetches the rotated one.
  void forgetToken() => _token = null;

  Future<String?> _fcmToken() async {
    if (Platform.isIOS || Platform.isMacOS) {
      final apns = await _apnsToken();
      if (apns == null) {
        debugPrint('push: APNs never handed us a token — is the capability enabled?');
        return null;
      }
    }
    return _messaging.getToken();
  }

  /// Waits for APNs, which is not instant and not guaranteed.
  ///
  /// Roughly five seconds in total. On a simulator, or a build without the push
  /// entitlement, it never arrives at all — hence a bounded wait rather than a
  /// loop that would hang registration forever.
  Future<String?> _apnsToken({int attempts = 10}) async {
    for (var i = 0; i < attempts; i++) {
      final token = await _messaging.getAPNSToken();
      if (token != null) return token;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return null;
  }

  Future<PushRegistration> _send(BridgeSettings settings, String token, String? installId) async {
    final client = _newClient();
    try {
      final request = await client.postUrl(settings.httpUri('/push/register'));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({
        'token': token,
        'platform': Platform.isIOS ? 'ios' : 'other',
        'installId': ?installId,
      }));
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200) {
        debugPrint('push: the bridge refused our token (${response.statusCode})');
        return const PushRegistration(PushReach.unreachable);
      }

      // `sending` is the bridge telling us whether it has an FCM service account.
      // Absent on older daemons, which could not report it and were assumed able —
      // keep assuming, since the alternative is telling everyone on an old bridge
      // that push is broken when it is not.
      final sending = _sendingFlag(body);
      return PushRegistration(
        sending ? PushReach.armed : PushReach.noCredential,
        at: DateTime.now(),
      );
    } finally {
      client.close(force: true);
    }
  }

  bool _sendingFlag(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['sending'] is bool) return decoded['sending'] as bool;
    } on Object {
      /* a 200 with a body we cannot read still means it took the token */
    }
    return true;
  }
}
