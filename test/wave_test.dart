/// Sending a wave: the action layer under the three buttons that reach it.
///
/// A wave is unlike the other presence actions in two ways worth pinning. It is
/// aimed at one person, so the id has to reach the collector intact; and it carries
/// its own rate limit, because the server does *not* — it will happily deliver a
/// mashed repeat 41 times in eight seconds — so the quiet is the app's to keep, and
/// a repeat has to fall silent here rather than reach the wire. The wire shape
/// itself — the action name Gather wants — lives in `direct_collector.dart`; this is
/// about the app's half.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:gather_companion/harness/fake_collector.dart';
import 'package:gather_companion/src/app_state.dart';

void main() {
  ({AppState state, FakeCollector collector}) wired() {
    final collector = FakeCollector();
    final state = AppState()..debugAttachCollector(collector);
    addTearDown(state.dispose);
    return (state: state, collector: collector);
  }

  test('forwards the target id to the collector, and reports it sent', () async {
    final (:state, :collector) = wired();

    final result = await state.sendWave('ada');

    expect(result.error, isNull);
    expect(result.sent, isTrue);
    expect(collector.waves, ['ada']);
  });

  test('swallows a repeat at the same person inside the cooldown', () async {
    final (:state, :collector) = wired();

    expect((await state.sendWave('ada')).sent, isTrue);
    // The second press lands well inside the 30s window: not sent, not an error,
    // and nothing more on the wire — so a caller confirms the first and only the
    // first, rather than reporting "Waved" on every mashed press.
    final repeat = await state.sendWave('ada');
    expect(repeat.sent, isFalse);
    expect(repeat.error, isNull);

    expect(collector.waves, ['ada'], reason: 'the repeat is held back, not resent');
  });

  test("a different person is never held back by another's cooldown", () async {
    final (:state, :collector) = wired();

    await state.sendWave('ada');
    final result = await state.sendWave('bob');

    expect(result.error, isNull);
    expect(result.sent, isTrue);
    expect(collector.waves, ['ada', 'bob']);
  });

  test('a failed send does not arm the cooldown, so a retry still goes', () async {
    final (:state, :collector) = wired();
    collector.failSends = true;

    final first = await state.sendWave('ada');
    expect(first.sent, isFalse);
    expect(first.error, isNotNull);
    expect(collector.waves, isEmpty);

    // A press that never reached the wire must stay retryable — the cooldown is for
    // waves that went, not for ones that failed on a dead socket.
    collector.failSends = false;
    final retry = await state.sendWave('ada');
    expect(retry.sent, isTrue);
    expect(collector.waves, ['ada']);
  });

  test('says so, and sends nothing, when there is no collector', () async {
    final state = AppState();
    addTearDown(state.dispose);

    final result = await state.sendWave('ada');

    expect(result.sent, isFalse);
    expect(result.error, contains('Not connected'));
  });

  test('an empty target is refused rather than sent', () async {
    final (:state, :collector) = wired();

    final result = await state.sendWave('');

    expect(result.sent, isFalse);
    expect(result.error, isNotNull);
    expect(collector.waves, isEmpty);
  });
}
