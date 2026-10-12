import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:gather_events/gather_events.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

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

  /// Whether the timezone database is loaded and `tz.local` points at this phone's
  /// zone. [scheduleReminder] needs it — `zonedSchedule` is the only scheduling API
  /// the plugin still offers, and it takes a zoned time. Tracked separately from
  /// [_ready] because the lookup can fail (a platform with no zone plugin) while
  /// the rest of notifications works fine; a reminder then falls back to UTC rather
  /// than not scheduling at all.
  bool _tzReady = false;

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
      // Not optional on Android, and not merely for completeness: `initialize`
      // throws outright if the platform it is running on has no settings here,
      // so leaving it out is not "no notifications on Android" but a crash at
      // launch. The icon is the launcher's, which is what a notification without
      // its own artwork should look like.
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    );
    await _plugin.initialize(settings);
    _ready = true;
    await _initTimezone();
  }

  /// Loads the zone database and points `tz.local` at this phone, once. Wrapped
  /// whole: on a platform where the zone plugin is absent (a bare test host) this
  /// leaves `tz.local` at its UTC default, and [scheduleReminder] still fires — a
  /// reminder at the wrong offset is a far smaller failure than no reminder, and
  /// `_tzReady` stays false so it is at least honest about it.
  Future<void> _initTimezone() async {
    if (_tzReady) return;
    try {
      tzdata.initializeTimeZones();
      final name = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(name));
      _tzReady = true;
    } on Object {
      /* UTC fallback; reminders still schedule */
    }
  }

  /// Schedules a one-off reminder to fire at [when], or shows nothing if [when] is
  /// already past. Returns silently on a build where notifications never
  /// initialised (every widget test), the same guard [consider] uses.
  ///
  /// This is the app's *own* reminder for a meeting planned in the Plans tab —
  /// distinct from the `'event reminder'` in [consider], which is Gather's reminder
  /// for an event on the user's Google/Outlook calendar, scraped from the desktop
  /// client. The two never collide: Gather does not know about a plan made here
  /// unless it was mirrored into the phone's calendar, and a mirrored plan carries
  /// the OS's own alert instead (the Plans tab skips this call for those).
  Future<void> scheduleReminder({
    required int id,
    required DateTime when,
    required String title,
    required String body,
  }) async {
    if (!_ready) return;
    if (when.isBefore(DateTime.now())) return;
    await _initTimezone();
    try {
      await _plugin.zonedSchedule(
        id,
        title,
        body,
        tz.TZDateTime.from(when, tz.local),
        const NotificationDetails(
          iOS: DarwinNotificationDetails(presentAlert: true, presentSound: true),
          android: _android,
        ),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      );
    } on Object {
      /* a reminder that could not be set is not worth crashing a save over */
    }
  }

  /// Cancels a previously scheduled reminder. Safe to call for an id that was never
  /// scheduled — the plugin treats it as a no-op.
  Future<void> cancelReminder(int id) async {
    if (!_ready) return;
    try {
      await _plugin.cancel(id);
    } on Object {
      /* already gone, or the platform has nothing to cancel */
    }
  }

  /// The one channel, declared here so Android has somewhere to put these.
  ///
  /// Android groups notifications by channel and lets people silence one without
  /// silencing the app, so the split that matters to a person is the one to
  /// make. There is only one kind here — somebody did something deliberate that
  /// is worth interrupting you for — so there is one channel, and the settings
  /// screen's two switches stay this app's business rather than the system's.
  static const _android = AndroidNotificationDetails(
    'gather_companion.people',
    'People',
    channelDescription: 'Someone followed you, waved, or invited you to a meeting.',
    importance: Importance.high,
    priority: Priority.high,
  );

  /// Asks for permission explicitly, so the prompt appears when the user has
  /// just paired and understands why it is being asked.
  Future<void> requestPermission() async {
    await init();
    await _plugin
        .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(alert: true, badge: true, sound: true);
    // Android 13 and up. Below that, holding the permission in the manifest is
    // the whole of it and this resolves to nothing — which is why it is asked
    // rather than gated on a version check.
    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
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
        android: _android,
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
