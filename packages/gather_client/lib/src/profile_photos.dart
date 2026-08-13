/// Turning a `profilePictureId` into something you can actually load.
///
/// `SpaceUser.profilePictureId` is a `UserFile` id, and that is all it is. The
/// `UserFile` rows *are* in the state dump — 60 of them on the reference space,
/// every one `type: "Profile"` — but the three URL fields on them
/// (`originalFileUrl`, `imageThumbnailUrl`, `downloadFileUrl`) come across as
/// msgpack-undefined on every single row. The path is there
/// (`<spaceId>/<uuid>.jpg`) and it is not enough: the bucket refuses an unsigned
/// request with `403`.
///
/// So there is exactly one route, and it is REST:
///
/// ```http
/// GET /spaces/:spaceId/files/:fileId
/// → 200 {"url": "https://profile-photos.gather.town/<path>?Expires=…&Signature=…"}
/// ```
///
/// Measured 2026-08-13 against a live space: 45 of 98 people had set a picture,
/// and every one of those ids resolved. The other 53 had no `profilePictureId`
/// at all rather than a broken one — bots and anonymous rows included, which
/// share a single placeholder id that the API rejects as "Invalid UUID".
///
/// ## What the signed URL is like
///
/// A CloudFront signature with `Expires` **24 hours** out, and it needs **no
/// authorization header** — which is the property that matters, because it means
/// the URL can be handed straight to an image loader that knows nothing about
/// Gather. That is why this returns a URL rather than bytes.
///
/// ## Why it is cached this hard
///
/// One request per person, and a busy office is a hundred people. The map draws
/// every one of them and rebuilds four times a second, so an uncached lookup
/// would be a REST call per face per frame. Three things prevent that: resolved
/// URLs are held until shortly before they expire, in-flight requests are shared
/// rather than duplicated, and **failures are remembered too**. Without that last
/// one a person whose picture 404s would be re-requested forever.
library;

import 'dart:async';
import 'dart:convert';

import 'gather_auth.dart';

/// How long before the signature runs out we start asking for a new one.
///
/// Well inside the 24 hours Gather grants, so an image that begins loading just
/// as the URL turns over still finishes against the old one.
const _renewBefore = Duration(hours: 1);

/// How long a refusal is believed before trying again.
///
/// Long enough that a missing picture is not re-requested on every rebuild, short
/// enough that somebody setting one for the first time sees it the same session.
const _rememberFailure = Duration(minutes: 10);

class ProfilePhotos {
  // Assigned the long way round because a named parameter cannot be a private
  // initializing formal — same as `ActivityFeed` and `DirectCollector`.
  ProfilePhotos({
    required GatherAuth auth,
    GatherHttp http = const IoGatherHttp(),
    String apiBase = gatherApiBase,
    DateTime Function()? clock,
  })  :
        // ignore: prefer_initializing_formals
        _auth = auth,
        // ignore: prefer_initializing_formals
        _http = http,
        // ignore: prefer_initializing_formals
        _apiBase = apiBase,
        _now = clock ?? (() => DateTime.now().toUtc());

  final GatherAuth _auth;
  final GatherHttp _http;
  final String _apiBase;
  final DateTime Function() _now;

  final Map<String, ({String? url, DateTime until})> _cache = {};
  final Map<String, Future<String?>> _inFlight = {};

  /// What we already know without asking, or null.
  ///
  /// Synchronous, so a `build` can paint a face it has already resolved without
  /// a `FutureBuilder` flashing a placeholder on every rebuild.
  String? cached(String fileId) {
    final hit = _cache[fileId];
    if (hit == null || !hit.until.isAfter(_now())) return null;
    return hit.url;
  }

  /// Whether [fileId] has been asked about and answered — including answered
  /// "no". Lets a caller tell "not yet known" from "known to have none".
  bool isResolved(String fileId) {
    final hit = _cache[fileId];
    return hit != null && hit.until.isAfter(_now());
  }

  /// A loadable URL for a profile picture, or null if there is not one.
  ///
  /// Never throws: a face that cannot be fetched is a fallback avatar, not an
  /// error worth propagating into a widget tree.
  Future<String?> urlFor({required String spaceId, required String fileId}) {
    final hit = _cache[fileId];
    if (hit != null && hit.until.isAfter(_now())) return Future.value(hit.url);

    return _inFlight[fileId] ??= _fetch(spaceId: spaceId, fileId: fileId)
        .whenComplete(() => _inFlight.remove(fileId));
  }

  Future<String?> _fetch({required String spaceId, required String fileId}) async {
    try {
      final token = await _auth.idToken();
      final uri = Uri.parse('$_apiBase/spaces/$spaceId/files/$fileId');
      final response = await _http.getJson(uri, token);
      if (response.status != 200) {
        return _remember(fileId, null, _now().add(_rememberFailure));
      }

      // JSON here, unlike the activity feed's msgpack — the API is not uniform
      // about which it answers with, so this route was checked rather than
      // assumed.
      final body = response.body is String
          ? jsonDecode(response.body! as String)
          : response.body;
      final url = body is Map ? body['url'] : null;
      if (url is! String || url.isEmpty) {
        return _remember(fileId, null, _now().add(_rememberFailure));
      }

      return _remember(fileId, url, _expiryOf(url));
    } on Object {
      // A dead network is not a missing picture, so it is forgotten sooner.
      return _remember(fileId, null, _now().add(const Duration(seconds: 30)));
    }
  }

  String? _remember(String fileId, String? url, DateTime until) {
    _cache[fileId] = (url: url, until: until);
    return url;
  }

  /// When to stop trusting a signed URL, read out of its own `Expires`.
  ///
  /// Taken from the URL rather than assumed to be 24 hours, so a change on
  /// Gather's side shortens our cache instead of leaving us serving links that
  /// have already died.
  DateTime _expiryOf(String url) {
    final seconds = int.tryParse(Uri.parse(url).queryParameters['Expires'] ?? '');
    if (seconds == null) return _now().add(const Duration(hours: 1));
    final expires = DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
    final renew = expires.subtract(_renewBefore);
    // A signature already inside its last hour is still worth using once.
    return renew.isAfter(_now()) ? renew : _now().add(const Duration(minutes: 1));
  }

  /// Forgets everything. For unpairing, where the next person's faces must not
  /// come from this one's cache.
  void clear() {
    _cache.clear();
    _inFlight.clear();
  }
}
