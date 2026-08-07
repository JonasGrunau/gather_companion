/// How good our connection to Gather is, in the four states the UI can draw.
///
/// This used to describe the socket to the computer-side bridge. It now describes
/// the app's own connection to Gather's game server, which is a better thing to show
/// someone: the bridge being asleep no longer means the app knows nothing.
library;

enum LinkState { idle, connecting, live, retrying }

class LinkStatus {
  const LinkStatus(this.state, [this.detail, this.needsPairing = false]);

  final LinkState state;
  final String? detail;

  /// The credential is dead and only pairing again will fix it.
  ///
  /// Kept distinct from [LinkState.retrying] because the two need opposite things
  /// from the user: one asks them to wait, the other asks them to act. Showing a
  /// spinner for a revoked token would leave someone staring at it indefinitely.
  final bool needsPairing;

  bool get isLive => state == LinkState.live;
}
