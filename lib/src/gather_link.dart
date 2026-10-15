/// Pulling a Gather destination out of a calendar event's free-text location.
///
/// When a meeting is held in Gather, the event its organiser makes carries a Gather
/// link as its location — `https://app.v2.gather.town/app/<spaceId>/<Name>?…`. That
/// is the one scrap of a read-only [GoogleEvent] the live office can act on: if the
/// link names the space this phone is already in, the Plans tab can walk the user
/// into it. This is the parser that turns the string into that intent, and nothing
/// more — resolving the room against the live map is [AppState.gatherRoomFor]'s job.
///
/// Deliberately forgiving on input and strict on output. A location is far more
/// often an address, a Zoom link or blank than a Gather one, so [tryParse] returns
/// null for anything it does not positively recognise, and the caller treats null as
/// "not a Gather link" — no button, never a wrong jump.
library;

/// A Gather link recognised in an event's location: the space it points at and,
/// when the link carries one, a hint at the room within it.
class GatherLink {
  const GatherLink({required this.spaceId, this.roomHint});

  /// The `SpaceUser` space id from the `/app/<spaceId>/…` path. Compared against the
  /// space this phone is connected to; a link to a different space is not one a
  /// single walk can reach, so the caller declines it.
  final String spaceId;

  /// A loose name for the room/area within the space, when the link carries one —
  /// from a recognised query parameter or the path tail past the space name. Matched
  /// case-insensitively against the live map's room names; null when the link names
  /// only the space, which lands the user at their usual spawn.
  final String? roomHint;

  /// Query parameters a Gather link uses to name a destination within the space. The
  /// exact key varies by how the link was minted, so several are accepted and the
  /// first present one wins.
  static const _roomParams = ['room', 'area', 'spawn', 'spawnId', 'meeting', 'name'];

  /// Parses [location] into a [GatherLink], or null when it is not a Gather link.
  ///
  /// Accepts only `*.gather.town` hosts with an `/app/<spaceId>/…` path. The space id
  /// is percent-decoded (Gather ids embed a backslash the URL escapes). A room hint
  /// is taken from the first recognised query parameter, falling back to the path
  /// segment past the space name.
  static GatherLink? tryParse(String? location) {
    if (location == null) return null;
    final trimmed = location.trim();
    if (trimmed.isEmpty) return null;

    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasScheme) return null;
    final host = uri.host.toLowerCase();
    if (host != 'gather.town' && !host.endsWith('.gather.town')) return null;

    final segments = [for (final s in uri.pathSegments) if (s.isNotEmpty) s];
    final appAt = segments.indexOf('app');
    if (appAt < 0 || appAt + 1 >= segments.length) return null;

    final spaceId = Uri.decodeComponent(segments[appAt + 1]).trim();
    if (spaceId.isEmpty) return null;

    return GatherLink(spaceId: spaceId, roomHint: _roomHint(uri, segments, appAt));
  }

  static String? _roomHint(Uri uri, List<String> segments, int appAt) {
    for (final key in _roomParams) {
      final value = uri.queryParameters[key]?.trim();
      if (value != null && value.isNotEmpty) return Uri.decodeComponent(value);
    }
    // Past `/app/<spaceId>/<name>`, any further segment is a room within the space.
    if (segments.length > appAt + 3) {
      final tail = Uri.decodeComponent(segments[appAt + 3]).trim();
      if (tail.isNotEmpty) return tail;
    }
    return null;
  }
}
