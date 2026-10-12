/// A meeting somebody planned ahead of time, kept on this phone.
///
/// Gather has no calendar of its own to read or write: its "calendar" is a
/// Google/Outlook mirror the desktop client reads, and the game socket carries no
/// scheduled-event model at all — only a live `clusterId` for a conversation that
/// is *already happening*. So a plan the user makes here lives here, in the
/// keychain ([CalendarStore]), and nowhere on Gather. The one bridge back to
/// Gather is optional: mirrored into the phone's own calendar it can reach the
/// Google/Outlook account Gather is connected to — see [CalendarMirror].
///
/// Deliberately not [Meeting]. That is a conversation happening right now, keyed
/// on Gather's `clusterId`, with live members read off the roster. This is the
/// opposite: a title and a time somebody typed, with a *place* rather than people —
/// the Gather room it is meant to happen in, so the card can walk you there when
/// the hour comes.
library;

/// One planned meeting.
class PlannedMeeting {
  const PlannedMeeting({
    required this.id,
    required this.title,
    required this.startsAt,
    required this.endsAt,
    this.roomStableId,
    this.roomName,
    this.floorId,
    this.x,
    this.y,
    this.remindMinutesBefore = 5,
    this.deviceEventId,
  });

  /// A stable local id. Generated once when the meeting is created and never
  /// reused, so it can key both the reminder notification and the device-calendar
  /// mirror across launches.
  final String id;

  final String title;

  /// Start and end, in the phone's local time. Stored as ISO-8601 and parsed back
  /// with [DateTime.parse] — which keeps the offset that was written, so a meeting
  /// does not slide an hour when the phone crosses a daylight boundary before it.
  final DateTime startsAt;
  final DateTime endsAt;

  /// The Gather room this is meant to happen in, if one was chosen. [roomStableId]
  /// is [SpaceRoom.stableId] — the id that survives a floor-plan reload and that
  /// `deskId`/`goToRoom` already key on — and [roomName] is its label, kept so the
  /// card can say "Green Park" without a live map to resolve the id against.
  final String? roomStableId;
  final String? roomName;

  /// The floor the room is on, when it was known at creation. A meeting on another
  /// floor is not one a single walk can reach, the same ceiling the warp paths hit.
  final String? floorId;

  /// A fallback tile, for a place picked by tapping the map rather than by naming a
  /// room. Used only when [roomStableId] resolves to nothing on the live map.
  final num? x;
  final num? y;

  /// How long before [startsAt] to raise the reminder. Five minutes by default,
  /// matching Gather's own event reminders.
  final int remindMinutesBefore;

  /// The id the device-calendar mirror handed back, or null when this meeting was
  /// never mirrored. Held so an edit updates the same calendar event and a delete
  /// removes it rather than orphaning it. See [CalendarMirror].
  final String? deviceEventId;

  /// When the reminder should fire. Null when it is already in the past — the
  /// scheduler skips those rather than firing a notification for a meeting that
  /// has started.
  DateTime get remindAt => startsAt.subtract(Duration(minutes: remindMinutesBefore));

  bool get isPast => endsAt.isBefore(DateTime.now());

  /// A copy with the device-calendar id filled in (or cleared). The only field the
  /// mirror owns, so the only one with a dedicated wither.
  PlannedMeeting withDeviceEventId(String? deviceEventId) => PlannedMeeting(
        id: id,
        title: title,
        startsAt: startsAt,
        endsAt: endsAt,
        roomStableId: roomStableId,
        roomName: roomName,
        floorId: floorId,
        x: x,
        y: y,
        remindMinutesBefore: remindMinutesBefore,
        deviceEventId: deviceEventId,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'startsAt': startsAt.toIso8601String(),
        'endsAt': endsAt.toIso8601String(),
        'roomStableId': roomStableId,
        'roomName': roomName,
        'floorId': floorId,
        'x': x,
        'y': y,
        'remindMinutesBefore': remindMinutesBefore,
        'deviceEventId': deviceEventId,
      };

  /// Built back from storage. A record missing a required field is not a meeting we
  /// can show, so the caller ([CalendarStore]) drops the whole row rather than
  /// surfacing a half-one — the same stance the credential store takes.
  factory PlannedMeeting.fromJson(Map<String, Object?> json) => PlannedMeeting(
        id: json['id']! as String,
        title: json['title']! as String,
        startsAt: DateTime.parse(json['startsAt']! as String),
        endsAt: DateTime.parse(json['endsAt']! as String),
        roomStableId: json['roomStableId'] as String?,
        roomName: json['roomName'] as String?,
        floorId: json['floorId'] as String?,
        x: json['x'] as num?,
        y: json['y'] as num?,
        remindMinutesBefore: (json['remindMinutesBefore'] as num?)?.toInt() ?? 5,
        deviceEventId: json['deviceEventId'] as String?,
      );
}
