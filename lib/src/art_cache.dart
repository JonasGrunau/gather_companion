import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// What a set of URLs was asked for, so a caller can *replace* its last request
/// rather than only add to it.
///
/// The office's URL set is not stable while the state dump is landing: a
/// furniture URL carries a `?t=` cache-buster taken from the `CatalogItem` row,
/// and the `CatalogItemVariant` naming the sprite can arrive in an earlier frame
/// than the item does. Art built in between resolves the same picture to a
/// different URL, and while [prefetch] could only add, both spellings stayed in
/// the queue — up to 477 requests for pictures nobody would draw, fetched *ahead*
/// of the real ones because the queue is in insertion order. Grouping lets the
/// office's request be superseded while the avatars' is left alone.
enum ArtRequest {
  /// Floors, walls and furniture — everything in `SpaceArt.urls`.
  office,

  /// Avatar spritesheets, which come and go with the roster.
  avatars,
}

/// The office's artwork, fetched once and kept.
///
/// Gather ships no tileset. The client resolves one URL per floor texture, per wall
/// piece and per furniture variant, and fetches each on its own — so this does the
/// same. On the measured space that is 573 images totalling **222 KB**, because
/// every sprite is a few hundred bytes of pixel art; the whole office costs less
/// than one photograph.
///
/// Two caches, for two different problems:
///
///  - **In memory**, decoded, because a [ui.Image] is what the painter can draw and
///    decoding 573 PNGs on every rebuild would be absurd.
///  - **On disk**, encoded, because the art changes only when somebody redecorates.
///    The directory is the system temp one: iOS may purge it, and being purged
///    costs a re-download of a quarter of a megabyte, so nothing here is precious
///    enough for application support.
///
/// Loads are capped at [_concurrency] at a time and reported by [ChangeNotifier] —
/// coalesced, since 573 notifications would be 573 repaints of a map that is only
/// getting gradually less blank.
///
/// ## A failure is usually a delay, not an answer
///
/// This used to keep a plain `Set` of dead URLs, on the reasoning that the thing
/// worth guarding against was a 404: one request rather than one per repaint, and
/// the map simply has a hole in it. That was the right shape for a missing file and
/// the wrong one for a missing *network*. The whole office is asked for in one burst
/// the moment the map lands, which on a phone is exactly the moment the radio may
/// still be coming up or a handover from wifi to cellular is in progress, and a
/// `SocketException` recorded as "this image does not exist" was permanent: nothing
/// ever asked again, [settled] went true, the legend went away, and the office
/// stayed a schematic for the life of the process. The screen holds one of these
/// inside an `IndexedStack` that is never rebuilt, so "the life of the process" is
/// literal — a bad half-second at launch cost you the artwork until you force-quit.
///
/// So failures are now told apart. An answer that will not change — a 404, an empty
/// body, bytes that are not a picture — retires the URL immediately, exactly as
/// before. Anything that means *not now* — a dropped socket, an unfinished TLS
/// handshake, a 429 or a 5xx from the CDN under a burst of 573 requests, or a
/// request that simply went quiet — is retried on a doubling backoff and only given
/// up on after [_tries] goes, which is about a minute of patience per image.
///
/// [_deadline] matters as much as the retry does. [HttpClient] has no request
/// deadline of its own and no connection timeout by default, so a socket that goes
/// quiet held one of the [_concurrency] slots for as long as the process lived;
/// eight of those and the office never finished drawing however healthy the network
/// became afterwards.
class ArtCache extends ChangeNotifier {
  ArtCache({
    Directory? directory,
    Future<Uint8List?> Function(String url)? fetch,
    Duration? backoff,
  }) {
    // Assigned here rather than as initializing formals: a named parameter cannot
    // be named `_directory` or `_fetch`, and the directory is filled in lazily
    // anyway when nothing is passed.
    _directory = directory;
    _fetch = fetch;
    _backoff = backoff ?? _defaultBackoff;
  }

  static const _concurrency = 8;

  /// How long to sit on "another image arrived" before repainting. Long enough to
  /// batch a burst, short enough that the map visibly fills in.
  static const _coalesce = Duration(milliseconds: 120);

  /// How long one image gets before its slot is taken back. Generous, because these
  /// are a few hundred bytes each and the only thing being guarded against is
  /// silence.
  static const _deadline = Duration(seconds: 12);

  /// The same, for the connection alone — a host that will not answer at all should
  /// not spend the whole [_deadline] proving it.
  static const _connect = Duration(seconds: 8);

  /// Goes per image, including the first.
  static const _tries = 8;

  /// The wait before the second go. It doubles from here up to [_longestBackoff],
  /// so the seven waits behind [_tries] are 0.5s, 1, 2, 4, 8, 16 and 30 — a little
  /// over a minute of trying before an image is called lost. That is deliberately
  /// longer than it takes a phone to finish changing its mind about which radio it
  /// is on, which is the outage this exists for.
  static const _defaultBackoff = Duration(milliseconds: 500);
  static const _longestBackoff = Duration(seconds: 30);

  /// Where bytes come from, when it is not the network.
  ///
  /// The seam a test needs: injecting this replaces both halves of the fetch, so a
  /// test can hand over known pixels without a socket, a temp directory, or any
  /// knowledge of how this file names things on disk.
  Future<Uint8List?> Function(String url)? _fetch;

  /// The first backoff, injectable so a test of the retry does not have to wait out
  /// a real one.
  late final Duration _backoff;

  HttpClient? _client;
  Directory? _directory;

  /// Monotonic, and started with the cache: backoffs are measured against this
  /// rather than against the wall clock, which a phone changes under you.
  final _clock = Stopwatch()..start();

  final Map<String, ui.Image> _images = {};

  /// What each caller last asked for, and the union of it. See [ArtRequest].
  final Map<ArtRequest, Set<String>> _asked = {};
  final Set<String> _wanted = {};

  final Set<String> _inFlight = {};

  /// URLs that did not answer with an image, with how many goes they have had and
  /// when the next one is due.
  final Map<String, _Lapse> _lapsed = {};

  /// Wanted URLs already decoded, and wanted URLs that will not be coming.
  ///
  /// Counters rather than counted on demand: [loaded] is read once per paint and
  /// both were `Map.length` back when every key of `_images` was by definition
  /// still wanted. Recounted whenever [_wanted] changes and once per coalesced
  /// notification, which is the same 120ms of staleness the repaint already has.
  int _have = 0;
  int _lost = 0;

  Timer? _pending;
  Timer? _waking;
  bool _disposed = false;

  /// The decoded image, or null while it is still coming.
  ui.Image? operator [](String url) => _images[url];

  int get loaded => _have;

  /// Images that will not be coming: an answer that will not change, or every go
  /// spent. A hole in the floor.
  int get failed => _lost;

  int get wanted => _wanted.length;

  /// Whether everything asked for has either arrived or been given up on.
  ///
  /// An image waiting out a backoff is neither, which is the point: while this was
  /// "loaded + failed >= wanted" a burst that failed against a dead radio settled
  /// instantly, and the legend saying the office was still being drawn — the one
  /// signal that anything was wrong — disappeared.
  bool get settled => _have + _lost >= _wanted.length;

  /// Ask for these, and stop asking for anything else previously requested under
  /// [group].
  ///
  /// Safe to call on every build: an unchanged set is a no-op, and the order images
  /// arrive in does not matter to a painter that skips what it does not have.
  /// Nothing already decoded is thrown away when a request is superseded — the
  /// picture is the same picture whichever spelling of the URL fetched it, and
  /// evicting on a set difference would make an avatar vanish and re-download every
  /// time somebody walked off the floor and back onto it.
  void prefetch(Iterable<String> urls, {ArtRequest group = ArtRequest.office}) {
    final set = urls.toSet();
    final before = _asked[group];
    if (before != null && before.length == set.length && before.containsAll(set)) {
      return;
    }
    _asked[group] = set;

    final union = {for (final asked in _asked.values) ...asked};
    // Anything dropped stops being wanted *and* stops being remembered as a
    // failure: if it is ever asked for again it deserves a fresh go rather than
    // whatever a superseded request left behind.
    for (final url in _wanted) {
      if (!union.contains(url)) _lapsed.remove(url);
    }
    _wanted
      ..clear()
      ..addAll(union);
    _recount();
    // Superseding a request moves [loaded] and [wanted] without an image having
    // arrived, and can even settle the cache outright when the new set is one that
    // is already decoded. Coalesced like everything else, so asking on every build
    // is still free.
    _schedule();
    unawaited(_pump());
  }

  Future<void> _pump() async {
    while (!_disposed && _inFlight.length < _concurrency) {
      final next = _next();
      if (next == null) break;
      _inFlight.add(next);
      unawaited(_load(next).whenComplete(() {
        _inFlight.remove(next);
        if (!_disposed) unawaited(_pump());
      }));
    }
    _wakeForRetry();
  }

  /// The next URL worth asking for: one never tried, or one whose backoff is up.
  String? _next() {
    final now = _clock.elapsed;
    for (final url in _wanted) {
      if (_images.containsKey(url) || _inFlight.contains(url)) continue;
      final lapse = _lapsed[url];
      if (lapse == null) return url;
      final readyAt = lapse.readyAt;
      if (readyAt != null && readyAt <= now) return url;
    }
    return null;
  }

  /// Wake up when the earliest waiting image is due.
  ///
  /// Without this a retry never happens: [_pump] is driven by a load finishing or by
  /// [prefetch] finding something new, and a queue where everything left is sitting
  /// out a backoff has neither. Only *future* waits are armed — anything already due
  /// was either just taken by the loop above or is waiting on a slot, and a slot
  /// freeing re-pumps on its own. Arming a zero-length timer for those would spin.
  void _wakeForRetry() {
    if (_disposed) return;
    final now = _clock.elapsed;
    Duration? soonest;
    for (final url in _wanted) {
      if (_inFlight.contains(url)) continue;
      final readyAt = _lapsed[url]?.readyAt;
      if (readyAt == null || readyAt <= now) continue;
      if (soonest == null || readyAt < soonest) soonest = readyAt;
    }
    _waking?.cancel();
    _waking = soonest == null
        ? null
        : Timer(soonest - now, () {
            _waking = null;
            if (!_disposed) unawaited(_pump());
          });
  }

  Future<void> _load(String url) async {
    File? file;
    try {
      final override = _fetch;
      file = override == null ? await _fileFor(url) : null;
      var bytes = await _readCached(file);
      final cached = bytes != null;
      bytes ??= override == null
          ? await _download(url, file).timeout(_deadline)
          : await override(url);
      if (bytes == null) {
        // Answered, and not with an image: a 404, or an empty body. Another go
        // gets the same answer, so this is the hole in the floor.
        _retire(url);
        return;
      }

      final ui.Codec codec;
      try {
        codec = await ui.instantiateImageCodec(bytes);
      } on Object {
        // Bytes that are not a picture. Off the network that is a broken asset and
        // final. Off the disk it is more likely half a file — writes are atomic
        // now, but a build before this one could have left one behind and it would
        // fail to decode on every launch until the OS purged the directory — so the
        // file goes and the next go fetches it properly.
        if (cached) {
          await _discard(file);
          _lapse(url);
        } else {
          _retire(url);
        }
        return;
      }

      final frame = await codec.getNextFrame();
      codec.dispose();
      if (_disposed) {
        frame.image.dispose();
        return;
      }
      _images[url] = frame.image;
      _lapsed.remove(url);
    } on Object catch (error) {
      if (_transient(error)) {
        _lapse(url);
      } else {
        _retire(url);
      }
    } finally {
      _schedule();
    }
  }

  /// Whether a failure is the network's mood rather than the server's answer.
  static bool _transient(Object error) =>
      error is SocketException ||
      error is HandshakeException ||
      error is HttpException ||
      error is TimeoutException ||
      error is _Unavailable;

  /// Record a failure worth another go, and say when.
  void _lapse(String url) {
    final tries = (_lapsed[url]?.tries ?? 0) + 1;
    if (tries >= _tries) {
      _retire(url);
      return;
    }
    var wait = _backoff * (1 << (tries - 1));
    if (wait > _longestBackoff) wait = _longestBackoff;
    _lapsed[url] = _Lapse(tries: tries, readyAt: _clock.elapsed + wait);
  }

  /// Record a failure that is an answer, or the last of [_tries] goes: no more.
  void _retire(String url) =>
      _lapsed[url] = _Lapse(tries: (_lapsed[url]?.tries ?? 0) + 1, readyAt: null);

  Future<Uint8List?> _readCached(File? file) async {
    if (file == null || !await file.exists()) return null;
    final bytes = await file.readAsBytes();
    return bytes.isEmpty ? null : bytes;
  }

  Future<Uint8List?> _download(String url, File? file) async {
    final client = _client ??= (HttpClient()..connectionTimeout = _connect);
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      // "Come back later" and "no" are different sentences. Asking a CDN for 573
      // pictures in one burst earns the first often enough to be worth telling
      // apart from a missing file.
      if (response.statusCode == HttpStatus.tooManyRequests ||
          response.statusCode >= HttpStatus.internalServerError) {
        throw _Unavailable(response.statusCode);
      }
      return null;
    }
    final bytes = await consolidateHttpClientResponseBytes(response);
    if (file != null) await _store(file, bytes);
    return bytes;
  }

  /// Best effort, and atomically.
  ///
  /// A cache that cannot write is still a cache that works; one that leaves half a
  /// PNG behind is worse than one that leaves nothing, because the half file is
  /// what every later launch reads instead of the network. Written under a
  /// neighbouring name and renamed into place, so the file the next run finds is
  /// either the whole image or is not there.
  Future<void> _store(File file, Uint8List bytes) async {
    try {
      await file.parent.create(recursive: true);
      final part = File('${file.path}.part');
      await part.writeAsBytes(bytes, flush: true);
      await part.rename(file.path);
    } catch (_) {}
  }

  Future<void> _discard(File? file) async {
    if (file == null) return;
    try {
      await file.delete();
    } catch (_) {}
  }

  /// Where a URL lands on disk. The URL itself is the name, with everything
  /// awkward replaced — readable in a file listing, and collision-free in a way a
  /// hash would not visibly be.
  Future<File?> _fileFor(String url) async {
    try {
      final directory = _directory ??= Directory('${Directory.systemTemp.path}/gather-art');
      final name = url.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
      return File('${directory.path}/${name.length > 180 ? name.substring(name.length - 180) : name}');
    } catch (_) {
      return null;
    }
  }

  void _recount() {
    var have = 0;
    var lost = 0;
    for (final url in _wanted) {
      if (_images.containsKey(url)) {
        have++;
      } else if (_lapsed[url]?.spent ?? false) {
        lost++;
      }
    }
    _have = have;
    _lost = lost;
  }

  void _schedule() {
    if (_disposed || _pending != null) return;
    _pending = Timer(_coalesce, () {
      _pending = null;
      if (_disposed) return;
      _recount();
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _pending?.cancel();
    _waking?.cancel();
    for (final image in _images.values) {
      image.dispose();
    }
    _images.clear();
    _client?.close(force: true);
    super.dispose();
  }
}

/// One image's failures: how many goes it has had, and when the next is due.
/// A null [readyAt] is "no more goes".
class _Lapse {
  const _Lapse({required this.tries, required this.readyAt});

  final int tries;
  final Duration? readyAt;

  bool get spent => readyAt == null;
}

/// The server is there and is saying "not now" — a 429, or the 5xx family.
class _Unavailable implements Exception {
  const _Unavailable(this.status);

  final int status;

  @override
  String toString() => 'the server answered $status';
}
