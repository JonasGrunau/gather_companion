import 'package:flutter_test/flutter_test.dart';
import 'package:gather_companion/src/pairing.dart';
import 'package:gather_companion/src/relevance.dart';
import 'package:gather_events/gather_events.dart';

/// The feed's whole job is deciding what deserves someone's attention, so that
/// decision is pinned down here rather than left to whoever edits the switch next.
void main() {
  final at = DateTime(2026, 8, 4, 12, 30);
  String nameFor(String id) => id == 'them' ? 'Alex' : id;

  EventLook look(GatherEvent event) => lookOf(event, nameFor);

  group('relevance', () {
    test('being followed is an alert, and says who by name', () {
      final result = look(FollowEvent(
        at: at,
        source: EventSource.cdp,
        followerId: 'them',
        targetId: 'me',
        started: true,
        targetIsSelf: true,
      ));
      expect(result.relevance, Relevance.alert);
      expect(result.title, 'Alex is following you');
      expect(result.subject, 'them');
      expect(result.detail, isNull, reason: 'an observed follow needs no caveat');
    });

    test('an inferred follow says so, so a guess is not read as a fact', () {
      final result = look(FollowEvent(
        at: at,
        source: EventSource.cdp,
        confidence: Confidence.inferred,
        followerId: 'them',
        targetId: 'me',
        started: true,
        targetIsSelf: true,
      ));
      expect(result.relevance, Relevance.alert);
      expect(result.detail, contains('guessed'));
    });

    test('somebody stopping following is notable, not an alert', () {
      final result = look(FollowEvent(
        at: at,
        source: EventSource.cdp,
        followerId: 'them',
        targetId: 'me',
        started: false,
        targetIsSelf: true,
      ));
      expect(result.relevance, Relevance.notable);
      expect(result.isAlert, isFalse);
    });

    test('me following someone else is background — I already know', () {
      final result = look(FollowEvent(
        at: at,
        source: EventSource.cdp,
        followerId: 'me',
        targetId: 'them',
        started: true,
        targetIsSelf: false,
      ));
      expect(result.relevance, Relevance.ambient);
    });

    test('screen sharing is notable; mics and cameras are not', () {
      expect(
        look(MediaChangedEvent(
          at: at,
          source: EventSource.log,
          playerId: 'them',
          track: MediaTrack.screen,
          paused: false,
        )).relevance,
        Relevance.notable,
      );
      for (final track in [MediaTrack.audio, MediaTrack.video]) {
        expect(
          look(MediaChangedEvent(
            at: at,
            source: EventSource.log,
            playerId: 'them',
            track: track,
            paused: true,
          )).relevance,
          Relevance.ambient,
          reason: '$track flickers constantly and must not fill the feed',
        );
      }
    });

    test('chat is notable and keeps the message as the detail', () {
      final result = look(ChatMessageEvent(
        at: at,
        source: EventSource.cdp,
        playerId: 'them',
        text: 'standup in five',
      ));
      expect(result.relevance, Relevance.notable);
      expect(result.title, 'Alex');
      expect(result.detail, 'standup in five');
    });

    test('roster churn and transport chatter stay in the background', () {
      final ambient = <GatherEvent>[
        PlayerSpaceEvent(at: at, source: EventSource.log, playerId: 'them', joined: true),
        MediaConnectionEvent(
          at: at,
          source: EventSource.log,
          playerId: 'them',
          state: 'Connected',
        ),
        SelfChangedEvent(at: at, source: EventSource.log, audioEnabled: false),
        BridgeStatusEvent(at: at, source: EventSource.bridge, collector: 'cdp', healthy: true),
        RawEvent(at: at, source: EventSource.log, rawType: 'app.badge', text: '3'),
      ];
      for (final event in ambient) {
        expect(look(event).relevance, Relevance.ambient, reason: event.type);
      }
    });

    test('collector health reads as prose, not as the bridge\'s identifiers', () {
      String titleOf(String collector, {required bool healthy}) => look(BridgeStatusEvent(
            at: at,
            source: EventSource.bridge,
            collector: collector,
            healthy: healthy,
          )).title;

      expect(titleOf('gather', healthy: true), 'Gather connected');
      expect(titleOf('gather', healthy: false), 'Gather disconnected');
      expect(titleOf('logTail', healthy: true), 'Connected to log');
      expect(titleOf('logTail', healthy: false), 'Disconnected from log');
      // A collector this build has never heard of still renders.
      expect(titleOf('somethingNew', healthy: true), 'somethingNew connected');
    });

    test('an unmodelled event still renders rather than crashing the feed', () {
      final result = look(RawEvent(
        at: at,
        source: EventSource.log,
        rawType: 'something.new',
        text: '',
      ));
      expect(result.title, 'Something new');
      expect(result.detail, isNull);
    });
  });

  group('pairing codes', () {
    test('a scanned payload carries the address as well as the code', () {
      final payload = PairPayload.parse('192.168.178.81:7799:MAMGT98C');
      expect(payload, isNotNull);
      expect(payload!.code, 'MAMGT98C');
      expect(payload.host, '192.168.178.81');
      expect(payload.port, 7799);
      expect(payload.hasAddress, isTrue);
    });

    test('anything that is not a pairing code is ignored', () {
      expect(PairPayload.parse('https://example.com'), isNull);
      expect(PairPayload.parse(''), isNull);
      expect(PairPayload.parse('WIFI:S:MyNetwork;T:WPA;'), isNull);
    });

    test('typed codes tolerate case and spacing', () {
      expect(normaliseCode('mamgt98c'), 'MAMGT98C');
      expect(normaliseCode('MAMG 98C'), isNull, reason: 'that is only seven characters');
      expect(normaliseCode('MAMG-T98C'), 'MAMGT98C');
    });

    test('ambiguous characters are refused rather than guessed at', () {
      // O, I, L, 0 and 1 are not in the alphabet; dropping them leaves the code
      // the wrong length, which is the honest outcome.
      expect(normaliseCode('MAMGT9OC'), isNull);
    });

    test('a bare host takes the default port', () {
      final address = PairPayload.parseAddress('jonas-macbook');
      expect(address?.host, 'jonas-macbook');
      expect(address?.port, 7799);
    });

    test('a nonsense address is refused', () {
      expect(PairPayload.parseAddress('not a host'), isNull);
      expect(PairPayload.parseAddress('host:99999'), isNull);
      expect(PairPayload.parseAddress(''), isNull);
    });
  });
}
