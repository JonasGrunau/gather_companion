import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

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
class ArtCache extends ChangeNotifier {
  ArtCache({Directory? directory, Future<Uint8List?> Function(String url)? fetch}) {
    // Assigned here rather than as initializing formals: a named parameter cannot
    // be named `_directory` or `_fetch`, and the directory is filled in lazily
    // anyway when nothing is passed.
    _directory = directory;
    _fetch = fetch;
  }

  static const _concurrency = 8;

  /// How long to sit on "another image arrived" before repainting. Long enough to
  /// batch a burst, short enough that the map visibly fills in.
  static const _coalesce = Duration(milliseconds: 120);

  /// Where bytes come from, when it is not the network.
  ///
  /// The seam a test needs: injecting this replaces both halves of the fetch, so a
  /// test can hand over known pixels without a socket, a temp directory, or any
  /// knowledge of how this file names things on disk.
  Future<Uint8List?> Function(String url)? _fetch;

  HttpClient? _client;
  Directory? _directory;

  final Map<String, ui.Image> _images = {};
  final Set<String> _wanted = {};
  final Set<String> _inFlight = {};

  /// URLs that answered something other than an image. Kept so a 404 costs one
  /// request rather than one per repaint; the map simply has a hole in it.
  final Set<String> _failed = {};

  Timer? _pending;
  bool _disposed = false;

  /// The decoded image, or null while it is still coming.
  ui.Image? operator [](String url) => _images[url];

  int get loaded => _images.length;
  int get failed => _failed.length;
  int get wanted => _wanted.length;

  /// Whether everything asked for has either arrived or failed.
  bool get settled => _images.length + _failed.length >= _wanted.length;

  /// Ask for these, if they are not already here or on their way.
  ///
  /// Safe to call on every build: it is a set difference, and the order images
  /// arrive in does not matter to a painter that skips what it does not have.
  void prefetch(Iterable<String> urls) {
    var added = false;
    for (final url in urls) {
      if (!_wanted.add(url)) continue;
      added = true;
    }
    if (added) unawaited(_pump());
  }

  Future<void> _pump() async {
    while (!_disposed && _inFlight.length < _concurrency) {
      final next = _wanted.firstWhere(
        (url) => !_images.containsKey(url) && !_inFlight.contains(url) && !_failed.contains(url),
        orElse: () => '',
      );
      if (next.isEmpty) return;
      _inFlight.add(next);
      unawaited(_load(next).whenComplete(() {
        _inFlight.remove(next);
        if (!_disposed) unawaited(_pump());
      }));
    }
  }

  Future<void> _load(String url) async {
    try {
      final override = _fetch;
      final file = override == null ? await _fileFor(url) : null;
      var bytes = await _readCached(file);
      bytes ??= override == null ? await _download(url, file) : await override(url);
      if (bytes == null) {
        _failed.add(url);
        return;
      }

      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      if (_disposed) {
        frame.image.dispose();
        return;
      }
      _images[url] = frame.image;
      _schedule();
    } catch (_) {
      // A failed tile is a hole in the floor, not a broken screen. The map is
      // decoration over data that arrived on the socket regardless.
      _failed.add(url);
      _schedule();
    }
  }

  Future<Uint8List?> _readCached(File? file) async {
    if (file == null || !await file.exists()) return null;
    final bytes = await file.readAsBytes();
    return bytes.isEmpty ? null : bytes;
  }

  Future<Uint8List?> _download(String url, File? file) async {
    final client = _client ??= HttpClient();
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      return null;
    }
    final bytes = await consolidateHttpClientResponseBytes(response);
    if (file != null) {
      // Best effort: a cache that cannot write is still a cache that works.
      try {
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes);
      } catch (_) {}
    }
    return bytes;
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

  void _schedule() {
    if (_disposed || _pending != null) return;
    _pending = Timer(_coalesce, () {
      _pending = null;
      if (!_disposed) notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _pending?.cancel();
    for (final image in _images.values) {
      image.dispose();
    }
    _images.clear();
    _client?.close(force: true);
    super.dispose();
  }
}
