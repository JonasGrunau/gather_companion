import 'package:flutter_test/flutter_test.dart';
import 'package:gather_companion/harness/call_scenarios.dart';
import 'package:gather_companion/harness/harness_data.dart';
import 'package:gather_companion/harness/scripted_call.dart';
import 'package:gather_companion/src/app_state.dart';
import 'package:gather_companion/ui/call_screen.dart';

void main() {
  // The accountIds the frames talk in, by cast order.
  String acc(int i) => kCast[i].accountId;

  group('scenarioFrame is a pure function of time', () {
    test('solo seats nobody and nobody talks', () {
      for (final ms in [0, 1200, 9000]) {
        final f = scenarioFrame(Scenario.solo, Duration(milliseconds: ms), 4);
        expect(f.count, 0);
        expect(f.speaking, isEmpty);
      }
    });

    test('group seats everyone and rests silent', () {
      final f = scenarioFrame(Scenario.group, const Duration(seconds: 2), 3);
      expect(f.count, 3);
      expect(f.speaking, isEmpty);
    });

    test('pair talks in bursts above and below the dwell', () {
      ScenarioFrame at(int ms) =>
          scenarioFrame(Scenario.pair, Duration(milliseconds: ms), 4);
      expect(at(0).count, 1);
      expect(at(500).speaking, {acc(0)}); // in the 2.5s on-phase
      expect(at(3000).speaking, isEmpty); // in the 1s off-phase
    });

    test('roundRobin hands the floor on, one speaker per 3s turn', () {
      ScenarioFrame at(int ms) =>
          scenarioFrame(Scenario.roundRobin, Duration(milliseconds: ms), 3);
      expect(at(0).speaking, {acc(0)});
      expect(at(1600).speaking, {acc(0)}, reason: 'still their turn past the dwell');
      expect(at(3000).speaking, {acc(1)});
      expect(at(6000).speaking, {acc(2)});
      expect(at(9000).speaking, {acc(0)}, reason: 'wraps back to the first');
    });

    test('debate: one holds the floor, the other talks over, then takes it', () {
      ScenarioFrame at(int ms) =>
          scenarioFrame(Scenario.debate, Duration(milliseconds: ms), 3);
      expect(at(2000).speaking, {acc(0)}, reason: 'A earns and holds');
      expect(at(6000).speaking, {acc(0), acc(1)}, reason: 'B talks over A');
      expect(at(9000).speaking, {acc(1)}, reason: 'A stops, B now holds');
    });

    test('briefNoise never sustains a speaker through the dwell', () {
      // Across a window far longer than the dwell, no single accountId is ever
      // continuously speaking for 1500ms, so the director can never promote.
      var longest = <String, int>{};
      final run = <String, int>{};
      String? prevSpeaker;
      for (var ms = 0; ms < 12000; ms += 100) {
        final f = scenarioFrame(Scenario.briefNoise, Duration(milliseconds: ms), 3);
        final who = f.speaking.isEmpty ? null : f.speaking.single;
        if (who != null && who == prevSpeaker) {
          run[who] = (run[who] ?? 0) + 100;
        } else if (who != null) {
          run[who] = 100;
        }
        if (who != null) {
          longest[who] = [longest[who] ?? 0, run[who]!].reduce((a, b) => a > b ? a : b);
        }
        prevSpeaker = who;
      }
      for (final held in longest.values) {
        expect(held, lessThan(kDwell.inMilliseconds),
            reason: 'no blip may reach the dwell');
      }
    });

    test('churn drops people and brings them back', () {
      final counts = {
        for (var ms = 0; ms < 8000; ms += 500)
          scenarioFrame(Scenario.churn, Duration(milliseconds: ms), 4).count,
      };
      expect(counts.length, greaterThan(1), reason: 'the roster size changes');
      expect(counts.reduce((a, b) => a < b ? a : b), lessThan(4));
    });
  });

  group('CallScenarioDriver applies a frame to AppState', () {
    test('seats participants and lights the right speaking ring', () {
      final state = AppState();
      addTearDown(state.dispose);
      final call = ScriptedCall();
      state.debugAttachCall(call);

      final driver = CallScenarioDriver(
        state: state,
        call: call,
        scenario: Scenario.roundRobin,
        participants: 3,
      );

      driver.applyAt(Duration.zero);

      // The media plane carries three people, audio-only.
      expect(state.call.participants, hasLength(3));

      final tiles = tilesFor(state);
      // A self tile, because the driver marks the camera captured.
      expect(tiles.any((t) => t.isSelf), isTrue);
      // The first speaker's ring is lit; the others are not.
      final ada = tiles.firstWhere((t) => t.label == 'Ada');
      expect(ada.speaking, isTrue);
      expect(tiles.where((t) => !t.isSelf && t.speaking), hasLength(1));
    });

    test('a later frame moves the ring to the next speaker', () {
      final state = AppState();
      addTearDown(state.dispose);
      final call = ScriptedCall();
      state.debugAttachCall(call);

      CallScenarioDriver(
        state: state,
        call: call,
        scenario: Scenario.roundRobin,
        participants: 3,
      ).applyAt(const Duration(seconds: 3));

      final tiles = tilesFor(state);
      final grace = tiles.firstWhere((t) => t.label == 'Grace');
      expect(grace.speaking, isTrue);
    });
  });
}
