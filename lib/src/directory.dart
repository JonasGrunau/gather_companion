/// Who you can reach, and the conversations already happening.
///
/// These are Warp Dial's view-models — the Dial tab is a phone-app over the same
/// roster the map draws, so it wants the *whole* office, including the people who
/// are offline, rather than only those with somewhere to draw them.
///
/// Deliberately not [MapPerson] and deliberately not `PlayerRef`. The map's model
/// needs coordinates and nothing else; `PlayerRef` carries who somebody is *to
/// you* (following, talking) and drops positions on principle. The directory wants
/// a third thing — a contact card: a name, whether they are here, and enough of a
/// position to warp next to them if they are. A [Contact] built from a
/// [RosterRow] is exactly that and no more.
library;

import 'package:gather_client/gather_client.dart';

/// One person in the office directory.
class Contact {
  const Contact({
    required this.id,
    required this.label,
    required this.isPresent,
    this.availability,
    this.clusterId,
    this.userAccountId,
    this.profilePictureId,
    this.floorId,
    this.x,
    this.y,
    this.status,
  });

  /// Built straight off a roster row. The label falls back to a short id the same
  /// way `peopleOnMap` does, so a row whose name has not arrived is still a chip
  /// rather than a blank.
  factory Contact.fromRow(RosterRow row) => Contact(
        id: row.id,
        label: row.name ?? (row.id.length <= 6 ? row.id : row.id.substring(0, 6)),
        isPresent: row.isPresent,
        availability: row.availability,
        clusterId: row.clusterId,
        userAccountId: row.userAccountId,
        profilePictureId: row.profilePictureId,
        floorId: row.floorId,
        x: row.x,
        y: row.y,
        status: row.status,
      );

  /// Their `SpaceUser` id — the game plane's name for them, and what picks their
  /// avatar colour and resolves their photo.
  final String id;
  final String label;

  /// Connected and not `Offline` — the same pair [RosterRow.isPresent] draws. The
  /// directory sorts on it (present first) and the UI dims the rest.
  final bool isPresent;

  /// `Active`, `Busy`, `Away`, the two `Focused` states, or `Offline` — the dot.
  final String? availability;

  /// The conversation they are in, if any. Shared, non-null values are a meeting.
  final String? clusterId;

  /// `UserAccount.id` — the media plane's name for them. Null until it has arrived.
  final String? userAccountId;

  /// `UserFile` id of their picture, resolved through `AppState.photoUrlFor`.
  final String? profilePictureId;

  /// Where they are, in tiles, when the roster has carried it. Absent on a row
  /// that has not moved since the dump — which is why [isReachable] checks it.
  final num? x;
  final num? y;
  final String? floorId;

  /// The line under their name, if Gather holds one that has not expired.
  final PersonStatus? status;

  /// Whether there is somewhere to warp to: present, and with a finite position.
  bool get isReachable => isPresent && x != null && y != null && x!.isFinite && y!.isFinite;
}

/// A conversation happening right now — Gather's own `clusterId`, with the people
/// in it.
///
/// Two or more people sharing a non-null `clusterId` are in one bubble; that is
/// the whole definition, the same one the call screen keys on. [roomName] is the
/// named area the members are sitting in when they are sitting in one, so the card
/// can say "Green Park" rather than only listing names.
class Meeting {
  const Meeting({
    required this.clusterId,
    required this.members,
    this.roomName,
    this.floorId,
    this.includesMe = false,
  });

  final String clusterId;

  /// Everybody in the conversation except me, as contacts. Never empty — a cluster
  /// that is only me is not a meeting to join.
  final List<Contact> members;

  /// The named room the conversation is in, when a majority of its members sit in
  /// one, else null ("Conversation with …").
  final String? roomName;

  /// The floor the conversation is on, when its placed members agree on one; null
  /// when they straddle floors or none is placed. A meeting on another floor is not
  /// one a single warp can reach.
  final String? floorId;

  /// Whether I am already in this conversation. First in the list, and not an
  /// offer to join something I am in.
  final bool includesMe;
}
