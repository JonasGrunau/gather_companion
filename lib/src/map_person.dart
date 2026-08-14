/// Somebody to draw on the map.
///
/// Deliberately not [PlayerRef]. That model carries who somebody *is* to you —
/// following you, talking — and has no coordinates, because this app's founding
/// argument is that being near somebody says nothing about whether they want you.
/// The map is the one screen where the coordinate is the actual subject, so it gets
/// its own small model rather than pushing positions into the shared one and
/// tempting every other screen to reason about proximity.
library;

import 'package:gather_client/gather_client.dart';

class MapPerson {
  const MapPerson({
    required this.id,
    required this.label,
    required this.x,
    required this.y,
    required this.isFollowingMe,
    required this.speaking,
    this.avatarUrl,
    this.direction,
    this.gait = Gait.walking,
    this.availability,
    this.isMe = false,
  });

  final String id;
  final String label;

  /// Tiles, fractionally — though what arrives here is always whole.
  ///
  /// Gather's positions are tiles: measured against a live dump of the office, all 98
  /// `SpaceUser` rows carry integer `position.x`/`y`, and the model has no sub-tile
  /// field at all. The fractions are what `MapMotion` writes when it walks a body
  /// between two of them, which is the difference between a walk and a hop.
  final double x;
  final double y;

  /// Drawn in the brand colour rather than grey — the same distinction the
  /// follower card makes, so the two screens agree about who matters.
  final bool isFollowingMe;

  final bool speaking;

  /// Their avatar spritesheet — 72 frames of 32×64, composited by Gather's own
  /// sprite service. Null for anybody whose outfit never arrived, which is normal:
  /// 66 of 111 people in the measured dump had one. They keep the dot.
  final String? avatarUrl;

  /// `Up`, `Down`, `Left`, `Right`, or null — which frame of the sheet to draw.
  final String? direction;

  /// Walking, running, or driving a go-kart — which *row* of the sheet to draw, and
  /// whether to put a kart under them.
  ///
  /// `speed.modifier` off the roster for everybody else; for me it comes from [Walk]
  /// instead, because the wire is a quarter of a second behind a walk that changes
  /// gait twice in that time and my own avatar is the one being watched closely.
  final Gait gait;

  /// `Active`, `Focused`, `FocusedCoworking`, `Busy`, `Away` — the dot on the name
  /// plate, and the reason it is worth carrying: a plate whose dot is always green
  /// says "available" about somebody who has marked themselves busy. `Offline` never
  /// reaches here; those rows are not drawn at all.
  final String? availability;

  /// Me. Drawn last and marked, because "where am I" is half of what this screen
  /// is for.
  final bool isMe;
}
