import 'dart:convert';
import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'settings.dart';

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

  /// The last token we successfully handed over, so reconnecting is cheap.
  String? _registered;

  /// Asks for notification permission and hands the resulting token to the bridge.
  ///
  /// Safe to call on every connect: it is idempotent on the bridge side, and
  /// short-circuits here once the token has not changed.
  Future<void> register(BridgeSettings settings) async {
    if (!settings.isComplete) return;
    try {
      final settingsResult = await _messaging.requestPermission();
      if (settingsResult.authorizationStatus == AuthorizationStatus.denied) {
        // Nothing to do, and nothing worth complaining about — the person said
        // no, and the in-app feed still works.
        return;
      }

      final token = await _fcmToken();
      if (token == null || token == _registered) return;
      if (await _send(settings, token)) _registered = token;
    } catch (error) {
      // Push is an enhancement. A phone that cannot register still gets the
      // whole feed over the socket, so this must never take the app down with
      // it — a Firebase misconfiguration would otherwise be a launch crash.
      debugPrint('push: could not register — $error');
    }
  }

  /// Keeps registration current when Firebase rotates the token.
  ///
  /// Rotation happens on reinstall, restore from backup, and occasionally on its
  /// own. Without this the bridge would keep pushing to a token that no longer
  /// resolves, and the phone would simply go quiet.
  Stream<String> get tokenRefreshes => _messaging.onTokenRefresh;

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

  Future<bool> _send(BridgeSettings settings, String token) async {
    final client = _newClient();
    try {
      final request = await client.postUrl(settings.httpUri('/push/register'));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({'token': token, 'platform': Platform.isIOS ? 'ios' : 'other'}));
      final response = await request.close();
      await response.drain<void>();
      if (response.statusCode != 200) {
        debugPrint('push: the bridge refused our token (${response.statusCode})');
        return false;
      }
      return true;
    } finally {
      client.close(force: true);
    }
  }
}
