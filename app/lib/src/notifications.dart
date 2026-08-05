import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:gather_events/gather_events.dart';

/// Local notifications for the two things worth interrupting you for.
///
/// A deliberate limitation, stated plainly rather than papered over: these fire
/// only while the app is running — in the foreground, or during the short window
/// the OS grants a backgrounded app before it suspends the WebSocket. Once the OS
/// suspends the app the socket is gone and nothing can be delivered until you
/// open it again, at which point the bridge replays everything that was missed
/// (see `BridgeClient.lastSeq`), so the *log* stays complete even though the
/// alerts do not. Waking a locked phone would need a push service driven from the
/// computer, which means a developer account and push credentials per platform.
class Notifier {
  Notifier({this.notifyOnFollow = true, this.notifyOnProximity = true});

  bool notifyOnFollow;
  bool notifyOnProximity;

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  int _nextId = 0;

  Future<void> init() async {
    if (_ready) return;
    const settings = InitializationSettings(
      // Deliberately requests nothing here. Initialising happens at launch, and a
      // permission sheet in someone's face before they have even paired is asking
      // for a "no". [requestPermission] asks once pairing has succeeded, when the
      // reason is obvious.
      iOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
    );
    await _plugin.initialize(settings);
    _ready = true;
  }

  /// Asks for permission explicitly, so the prompt appears when the user has
  /// just paired and understands why it is being asked.
  Future<void> requestPermission() async {
    await init();
    await _plugin
        .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(alert: true, badge: true, sound: true);
  }

  /// Decides whether an event deserves an alert, and shows it.
  Future<void> consider(GatherEvent event, String Function(String id) nameFor) async {
    if (!_ready) return;

    final (title, body) = switch (event) {
      FollowEvent(targetIsSelf: true, started: true, :final followerId) when notifyOnFollow => (
          'Someone is following you',
          '${nameFor(followerId)} started following you',
        ),
      ProximityEvent(near: true, :final playerId) when notifyOnProximity => (
          'Someone is next to you',
          '${nameFor(playerId)} is standing next to you',
        ),
      _ => (null, null),
    };

    if (title == null || body == null) return;

    await _plugin.show(
      _nextId++,
      title,
      body,
      const NotificationDetails(
        iOS: DarwinNotificationDetails(presentAlert: true, presentSound: true),
      ),
    );
  }
}
