/// Resolving a Gather meeting short-link (`/m/<linkId>`) to the space and room it
/// points at.
///
/// A calendar event held in Gather sometimes carries the long
/// `/app/<spaceId>/<Name>` link as its location, which [GatherLink] reads on its
/// own — but just as often it carries the short `https://app.v2.gather.town/m/<code>`
/// form. That code is opaque: the space, the area and the host are **not** in the
/// URL, they are behind one REST lookup. This is that lookup.
///
/// `GET {gatherApiBase}/meeting-join-info/<linkId>` answers JSON (not msgpack, unlike
/// most of the REST surface), public for a `Confirmed` link:
///
/// ```json
/// {"referenceId":"…","referenceType":"MeetingJoinInfo",
///  "normalizedGSState":{"MeetingJoinInfo":[
///    {"id":"…","spaceId":"…","linkId":"…","areaId":"…","status":"Confirmed","hostId":"…"}]}}
/// ```
///
/// The `areaId` is a `MapArea` id — the same id space as [SpaceRoom.id], so a
/// resolved link joins the live map by `id` directly (not `stableId`). `hostId` is
/// the meeting host's `SpaceUser` id, kept because a locked room is opened by asking
/// *somebody*, and the host is who answers.
library;

import 'gather_auth.dart';

/// What a `/m/<linkId>` resolves to: the space it lives in, the room within it, and
/// the host who can let you in.
class MeetingLinkInfo {
  const MeetingLinkInfo({
    required this.spaceId,
    required this.areaId,
    this.hostId,
  });

  /// The `SpaceUser` space id. Compared against the space this phone is in; a link
  /// to another space is not one a single walk can reach.
  final String spaceId;

  /// The `MapArea` id of the meeting room — joins [SpaceRoom.id] on the live map.
  final String areaId;

  /// The meeting host's `SpaceUser` id, when the payload carries one. Who a
  /// `requestToAccess` on a locked room is, in effect, addressed to.
  final String? hostId;

  @override
  String toString() =>
      'MeetingLinkInfo(spaceId: $spaceId, areaId: $areaId, hostId: $hostId)';
}

/// Resolves a `/m/<linkId>` short code against Gather's REST API.
///
/// Throws [GatherAuthException] when the token is refused or the endpoint answers
/// anything but 200 (both non-permanent — a bad link is news to the caller, not a
/// reason to re-pair), and a plain [FormatException] when the 200 body is not the
/// shape above (a meeting that never existed answers with an empty list).
Future<MeetingLinkInfo> resolveMeetingLink(GatherAuth auth, String linkId) async {
  final trimmed = linkId.trim();
  if (trimmed.isEmpty) {
    throw const FormatException('empty meeting link id');
  }

  final body = await auth.apiGet('/meeting-join-info/$trimmed');
  final row = _firstJoinInfo(body, trimmed);
  if (row == null) {
    throw FormatException('no meeting-join-info for "$trimmed"');
  }

  final spaceId = (row['spaceId'] as String?)?.trim() ?? '';
  final areaId = (row['areaId'] as String?)?.trim() ?? '';
  if (spaceId.isEmpty || areaId.isEmpty) {
    throw FormatException('meeting-join-info for "$trimmed" names no room');
  }

  final hostId = (row['hostId'] as String?)?.trim();
  return MeetingLinkInfo(
    spaceId: spaceId,
    areaId: areaId,
    hostId: hostId == null || hostId.isEmpty ? null : hostId,
  );
}

/// Digs the `MeetingJoinInfo` record out of the normalized-state envelope, matching
/// the asked-for [linkId] when several come back and falling back to the first.
Map<String, Object?>? _firstJoinInfo(Object? body, String linkId) {
  if (body is! Map) return null;
  final state = body['normalizedGSState'];
  if (state is! Map) return null;
  final rows = state['MeetingJoinInfo'];
  if (rows is! List || rows.isEmpty) return null;

  Map<String, Object?>? first;
  for (final row in rows) {
    if (row is! Map) continue;
    final typed = row.cast<String, Object?>();
    first ??= typed;
    if ((typed['linkId'] as String?)?.trim() == linkId) return typed;
  }
  return first;
}
