import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:gather_events/gather_events.dart';

/// Local notifications for the things worth interrupting you for.
///
/// Two kinds, from two different places. Somebody following you is read off
/// Gather's game socket. A wave, a meeting invite and an event reminder are
/// raised by Gather's own desktop client and scraped from its log, because they
/// exist in no Gather model — the bridge forwards them as
/// [NotificationShownEvent].
///
/// Both are deliberate acts by a person, which is the whole bar. Proximity used
/// to be a third kind and was by far the loudest: walking past a desk is not a
/// decision, and a phone that buzzes for it gets muted.
///
/// Worth knowing about the waves in particular: Gather suppresses its own
/// notification when its window has focus, and the bridge deliberately does not.
/// Looking at Gather on your Mac is no reason to withhold a wave from your phone.
///
/// These fire only while the app is running — in the foreground, or during the
/// short window the OS grants a backgrounded app before it suspends the
/// WebSocket. Waking a suspended or killed phone is push's job, and the bridge
/// sends those over FCM (see `bridge/lib/push.js`); iOS drops the duplicate while
/// the app is frontmost. On resume the bridge replays what was missed (see
/// `BridgeClient.lastSeq`), so the *log* is complete either way.
class Notifier {
  Notifier({
    this.notifyOnFollow = true,
    this.notifyOnGather = true,
  });

  bool notifyOnFollow;

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
