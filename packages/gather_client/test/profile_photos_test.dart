import 'package:gather_client/gather_client.dart';
import 'package:test/test.dart';

import 'fake_gather.dart';

/// What a hundred faces cost.
///
/// There is only one interesting question about this class, and it is not
/// whether a URL comes back. It is how many times Gather is asked. The map
/// draws everybody in the space and rebuilds four times a second; the activity
/// feed shows the same colleague on every row they waved from. Both are the
/// same handful of pictures asked for over and over, and every one of these
/// tests is a count.
void main() {
  GatherAuth authOn(GatherHttp http) => GatherAuth(
        // A token that is already valid, so nothing here goes near the refresh
        // endpoint and every request counted below is a file lookup.
        credentials: GatherCredentials(refreshToken: 'r', idToken: fakeJwt()),
        http: http,
      );

  test('the same picture wanted three times over is asked for once', () async {
    final http = _Files();
    final photos = ProfilePhotos(auth: authOn(http), http: http);

    // All three before any of them has answered — the case the feed actually
    // produces, where one person's rows are built in a single frame.
    final urls = await Future.wait([
      photos.urlFor(spaceId: 'space-1', fileId: 'file-1'),
      photos.urlFor(spaceId: 'space-1', fileId: 'file-1'),
      photos.urlFor(spaceId: 'space-1', fileId: 'file-1'),
    ]);

    expect(http.lookups, ['file-1']);
    expect(urls, everyElement(contains('file-1.jpg')));
  });

  test('and is not asked for again once it has been answered', () async {
    final http = _Files();
    final photos = ProfilePhotos(auth: authOn(http), http: http);

    await photos.urlFor(spaceId: 'space-1', fileId: 'file-1');
    await photos.urlFor(spaceId: 'space-1', fileId: 'file-1');
    // The synchronous read the widget tree uses, which must not start anything.
    photos.cached('file-1');

    expect(http.lookups, ['file-1']);
  });

  test('two people are two pictures, because the cache is keyed on the file', () async {
    final http = _Files();
    final photos = ProfilePhotos(auth: authOn(http), http: http);

    await Future.wait([
      photos.urlFor(spaceId: 'space-1', fileId: 'file-1'),
      photos.urlFor(spaceId: 'space-1', fileId: 'file-2'),
    ]);

    expect(http.lookups, ['file-1', 'file-2']);
  });

  test('a refusal is remembered too, or a missing picture is asked for forever', () async {
    final http = _Files(status: 404);
    final photos = ProfilePhotos(auth: authOn(http), http: http);

    expect(await photos.urlFor(spaceId: 'space-1', fileId: 'file-1'), isNull);
    expect(await photos.urlFor(spaceId: 'space-1', fileId: 'file-1'), isNull);

    expect(http.lookups, ['file-1']);
    // Answered "no" is still answered, which is what lets a caller tell it from
    // "not yet known".
    expect(photos.isResolved('file-1'), isTrue);
  });

  test('clearing forgets the lot, so the next account gets its own faces', () async {
    final http = _Files();
    final photos = ProfilePhotos(auth: authOn(http), http: http);

    await photos.urlFor(spaceId: 'space-1', fileId: 'file-1');
    photos.clear();
    await photos.urlFor(spaceId: 'space-1', fileId: 'file-1');

    expect(http.lookups, ['file-1', 'file-1']);
  });
}

/// Answers `/spaces/:id/files/:fileId` and writes down every file it was asked
/// about, in order.
class _Files implements GatherHttp {
  _Files({this.status = 200});

  final int status;
  final List<String> lookups = [];

  @override
  Future<({int status, Object? body})> getJson(Uri uri, String bearer) async {
    final fileId = uri.pathSegments.last;
    lookups.add(fileId);
    if (status != 200) return (status: status, body: null);
    // Shaped like the real one: a CloudFront signature a day out, which is what
    // [ProfilePhotos] reads its own cache lifetime from.
    final expires = DateTime.now().add(const Duration(hours: 24)).millisecondsSinceEpoch ~/ 1000;
    return (
      status: 200,
      body: {'url': 'https://profile-photos.gather.town/space-1/$fileId.jpg?Expires=$expires&Signature=s'},
    );
  }

  @override
  Future<({int status, Map<String, Object?> body})> postForm(Uri uri, Map<String, String> fields) =>
      throw UnimplementedError('nothing here should need a token minted');

  @override
  Future<({int status, List<int> body})> getBytes(Uri uri, String bearer) => throw UnimplementedError();

  @override
  Future<({int status, List<int> body})> postJson(Uri uri, String bearer, Object? body) =>
      throw UnimplementedError();
}
