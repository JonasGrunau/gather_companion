import 'package:flutter/material.dart';
import 'package:gather_events/gather_events.dart';

/// How much a given event deserves someone's attention.
///
/// The bridge publishes more than a person wants to read — it is a faithful
/// mirror of a busy space, and in a hundred-person office the honest firehose is
/// unreadable. So the feed shows [alert] and [notable] and keeps [ambient] behind
/// a toggle rather than dropping it: "who joined the space" is real information,
/// it is simply not what anyone opened this app for.
enum Relevance {
  /// Interrupts: someone is following you. The only thing in this tier.
  alert,

  /// Worth reading: somebody stopped following you, started sharing, said
  /// something, or Gather itself raised a notification.
  notable,

  /// True background: mic toggles, transport state, roster churn, your own
  /// device state. Hidden unless asked for.
  ambient,
}

/// One event, ready to draw.
class EventLook {
  const EventLook({
    required this.relevance,
    required this.icon,
    required this.title,
    required this.subject,
    this.detail,
  });

  final Relevance relevance;
  final IconData icon;

  /// The sentence, with the person's name already in it.
  final String title;

  /// Who it is about — drives the avatar. Null for events about nobody.
  final String? subject;

  /// Dim supporting text: confidence, message body.
  final String? detail;

  bool get isAlert => relevance == Relevance.alert;
}

/// Classifies and phrases an event in one pass.
EventLook lookOf(GatherEvent event, String Function(String) nameFor) {
  switch (event) {
    case FollowEvent(targetIsSelf: true, :final started, :final followerId):
      final who = nameFor(followerId);
      return EventLook(
        // Being followed is the whole reason this app exists. Somebody stopping
        // is merely the end of that, and does not need to shout.
        relevance: started ? Relevance.alert : Relevance.notable,
        icon: started ? Icons.directions_walk_rounded : Icons.person_off_outlined,
        title: started ? '$who is following you' : '$who stopped following you',
        subject: followerId,
        detail: event.confidence == Confidence.inferred ? 'guessed from movement' : null,
      );

    case FollowEvent(targetIsSelf: false, :final started, :final targetId):
      return EventLook(
        relevance: Relevance.ambient,
        icon: Icons.follow_the_signs_rounded,
        title: started ? 'You are following ${nameFor(targetId)}' : 'You stopped following',
        subject: started ? targetId : null,
      );

    case MediaChangedEvent(:final track, :final paused, :final playerId)
        when track == MediaTrack.screen:
      return EventLook(
        relevance: Relevance.notable,
        icon: Icons.screen_share_rounded,
        title: paused
            ? '${nameFor(playerId)} stopped sharing'
            : '${nameFor(playerId)} is sharing their screen',
        subject: playerId,
      );

    case ChatMessageEvent(:final playerId, :final text):
      return EventLook(
        relevance: Relevance.notable,
        icon: Icons.chat_bubble_rounded,
        title: nameFor(playerId),
        subject: playerId,
        detail: text,
      );

    case NotificationShownEvent(:final notificationType, :final title, :final body):
      return EventLook(
        relevance: Relevance.notable,
        icon: Icons.notifications_rounded,
        title: title ?? _humanise(notificationType),
        subject: null,
        detail: body,
      );

    // ---- ambient from here down ------------------------------------------------

    case MediaChangedEvent(:final track, :final paused, :final playerId):
      final who = nameFor(playerId);
      return EventLook(
        relevance: Relevance.ambient,
        icon: track == MediaTrack.audio
            ? (paused ? Icons.mic_off_rounded : Icons.mic_rounded)
            : (paused ? Icons.videocam_off_rounded : Icons.videocam_rounded),
        title: track == MediaTrack.audio
            ? (paused ? '$who muted' : '$who unmuted')
            : (paused ? '$who turned their camera off' : '$who turned their camera on'),
        subject: playerId,
      );

    case PlayerSpaceEvent(:final joined, :final playerId):
      return EventLook(
        relevance: Relevance.ambient,
        icon: joined ? Icons.login_rounded : Icons.logout_rounded,
        title: '${nameFor(playerId)} ${joined ? 'joined' : 'left'} the space',
        subject: playerId,
      );

    case MediaConnectionEvent(:final playerId, :final state):
      return EventLook(
        relevance: Relevance.ambient,
        icon: Icons.cable_rounded,
        title: '${nameFor(playerId)} — $state',
        subject: playerId,
      );

    case SelfChangedEvent():
      return EventLook(
        relevance: Relevance.ambient,
        icon: Icons.person_outline_rounded,
        title: event.summary,
        subject: null,
      );

    case SpaceChangedEvent(:final spaceName, :final spaceId):
      return EventLook(
        relevance: Relevance.ambient,
        icon: Icons.meeting_room_outlined,
        title: 'Space ${spaceName ?? _short(spaceId)}',
        subject: null,
      );

    case BridgeStatusEvent(:final headline, :final healthy, :final detail):
      return EventLook(
        relevance: Relevance.ambient,
        icon: healthy ? Icons.link_rounded : Icons.link_off_rounded,
        title: headline,
        subject: null,
        detail: detail,
      );

    case RawEvent(:final rawType, :final text):
      return EventLook(
        relevance: Relevance.ambient,
        icon: Icons.more_horiz_rounded,
        title: _humanise(rawType),
        subject: null,
        detail: text.orNull,
      );
  }
}

String _humanise(String raw) {
  final cleaned = raw.replaceAll('.', ' ').replaceAll('_', ' ').trim();
  if (cleaned.isEmpty) return 'Something happened';
  return cleaned[0].toUpperCase() + cleaned.substring(1);
}

String _short(String? id) => id == null ? 'unknown' : id.substring(0, id.length.clamp(0, 8));

extension _Blank on String {
  String? get orNull => trim().isEmpty ? null : this;
}
