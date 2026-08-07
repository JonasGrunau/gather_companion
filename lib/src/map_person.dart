/// Somebody to draw on the map.
///
/// Deliberately not [PlayerRef]. That model carries who somebody *is* to you —
/// following you, talking — and has no coordinates, because this app's founding
/// argument is that being near somebody says nothing about whether they want you.
/// The map is the one screen where the coordinate is the actual subject, so it gets
/// its own small model rather than pushing positions into the shared one and
/// tempting every other screen to reason about proximity.
library;

class MapPerson {
  const MapPerson({
    required this.id,
    required this.label,
    required this.x,
    required this.y,
    required this.isFollowingMe,
    required this.speaking,
  });

  final String id;
  final String label;
  final int x;
  final int y;

  /// Drawn in the brand colour rather than grey — the same distinction the
  /// follower card makes, so the two screens agree about who matters.
  final bool isFollowingMe;

  final bool speaking;
}
