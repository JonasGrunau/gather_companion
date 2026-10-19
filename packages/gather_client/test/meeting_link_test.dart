import 'package:gather_client/gather_client.dart';
import 'package:test/test.dart';

import 'fake_gather.dart';

/// What a `/m/<code>` short link turns into.
///
/// The code is opaque — no space, no room in the URL — so the only question worth
/// a test is whether one REST lookup hands back the three ids a walk needs, and
/// whether the shapes that are *not* a resolvable meeting are told apart from one
/// that is, so the caller never jumps somewhere on a half-read answer.
void main() {
  GatherAuth authOn(GatherHttp http) => GatherAuth(
        credentials: GatherCredentials(refreshToken: 'r', idToken: fakeJwt()),
        http: http,
      );

  test('resolves the space, room and host out of the join-info envelope', () async {
    final http = _JoinInfo(rows: [
      {
        'id': '067c52da',
        'spaceId': 'space-1',
        'linkId': 'ktvILgXphb',
        'areaId': 'area-9',
        'status': 'Confirmed',
        'hostId': 'host-7',
      },
    ]);

    final info = await resolveMeetingLink(authOn(http), 'ktvILgXphb');

    expect(http.lookups, ['ktvILgXphb']);
    expect(info.spaceId, 'space-1');
    expect(info.areaId, 'area-9');
    expect(info.hostId, 'host-7');
  });

  test('picks the row whose linkId matches when several come back', () async {
    final http = _JoinInfo(rows: [
      {'spaceId': 's-other', 'linkId': 'other', 'areaId': 'a-other'},
      {'spaceId': 'space-1', 'linkId': 'ktvILgXphb', 'areaId': 'area-9'},
    ]);

    final info = await resolveMeetingLink(authOn(http), 'ktvILgXphb');

    expect(info.spaceId, 'space-1');
    expect(info.areaId, 'area-9');
    expect(info.hostId, isNull, reason: 'no hostId in the payload stays null');
  });

  test('an empty join-info list is a FormatException, not a wrong jump', () async {
    final http = _JoinInfo(rows: const []);
    expect(
      () => resolveMeetingLink(authOn(http), 'ktvILgXphb'),
      throwsA(isA<FormatException>()),
    );
  });

  test('a row that names no area throws rather than resolving half a destination', () async {
    final http = _JoinInfo(rows: [
      {'spaceId': 'space-1', 'linkId': 'ktvILgXphb'},
    ]);
    expect(
      () => resolveMeetingLink(authOn(http), 'ktvILgXphb'),
      throwsA(isA<FormatException>()),
    );
  });

  test('a refusal surfaces as a GatherAuthException the caller can catch', () async {
    final http = _JoinInfo(rows: const [], status: 404);
    expect(
      () => resolveMeetingLink(authOn(http), 'ktvILgXphb'),
      throwsA(isA<GatherAuthException>()),
    );
  });

  test('an empty code never reaches the network', () async {
    final http = _JoinInfo(rows: const []);
    expect(
      () => resolveMeetingLink(authOn(http), '   '),
      throwsA(isA<FormatException>()),
    );
    expect(http.lookups, isEmpty);
  });
}

/// Answers `/meeting-join-info/:linkId` with a normalized-state envelope and writes
/// down every code it was asked about, in order.
class _JoinInfo implements GatherHttp {
  _JoinInfo({required this.rows, this.status = 200});

  final List<Map<String, Object?>> rows;
  final int status;
  final List<String> lookups = [];

  @override
  Future<({int status, Object? body})> getJson(Uri uri, String bearer) async {
    lookups.add(uri.pathSegments.last);
    if (status != 200) return (status: status, body: null);
    return (
      status: 200,
      body: {
        'referenceType': 'MeetingJoinInfo',
        'normalizedGSState': {'MeetingJoinInfo': rows},
      },
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
