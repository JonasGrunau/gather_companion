import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:gather_events/gather_events.dart';

/// Local notifications for the things worth interrupting you for.
///
/// Three kinds, and they come from two different places. Someone standing next to
/// you and someone following you are read off Gather's game socket. A wave, a
/// meeting invite and an event reminder are raised by Gather's own desktop client
/// and scraped from its log, because they exist in no Gather model — the bridge
/// forwards them as [NotificationShownEvent].
///
/// Worth knowing about the waves in particular: Gather suppresses its own
/// notification when its window has focus, and the bridge deliberately does not.
/// Looking at Gather on your Mac is no reason to withhold a wave from your phone.
///
/// A deliberate limitation, stated plainly rather than papered over: these fire
/// only while the app is running — in the foreground, or during the short window
/// the OS grants a backgrounded app before it suspends the WebSocket. Once the OS
/// suspends the app the socket is gone and nothing can be delivered until you
/// open it again, at which point the bridge replays everything that was missed
/// (see `BridgeClient.lastSeq`), so the *log* stays complete even though the
/// alerts do not. Waking a killed phone needs push — an APNs key and an FCM
/// sender in the bridge — which is not built yet.
class Notifier {
  Notifier({
    this.notifyOnFollow = true,
    this.notifyOnProximity = true,
    this.notifyOnGather = true,
  });

  bool notifyOnFollow;
  bool notifyOnProximity;

  /// Waves, meeting invites and event reminders, as raised by Gather itself.
  bool notifyOnGather;

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
      NotificationShownEvent(:final notificationType, :final title, :final body)
          when notifyOnGather =>
        (title ?? _gatherTitle(notificationType), body ?? _gatherBody(notificationType)),
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

/// Gather sends only a `type` for its own notifications — never a title or body,
/// on every sample seen so far. These are the sentences for the three types
/// observed in a real client: `wave`, `meeting invite`, `event reminder`.
String _gatherTitle(String type) => switch (type) {
      'wave' => 'Someone waved at you',
      'meeting invite' => 'Meeting invite',
      'event reminder' => 'Event reminder',
      _ => 'Gather',
    };

String _gatherBody(String type) => switch (type) {
      'wave' => 'Someone is trying to get your attention in Gather',
      'meeting invite' => 'You have been invited to a meeting',
      'event reminder' => 'An event on your calendar is starting',
      // An unrecognised type is still worth showing — Gather thought it was worth
      // interrupting someone for, and a new one should surface rather than vanish.
      _ => type,
    };
