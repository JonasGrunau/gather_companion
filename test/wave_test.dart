/// Sending a wave: the action layer under the three buttons that reach it.
///
/// A wave is unlike the other presence actions in two ways worth pinning. It is
/// aimed at one person, so the id has to reach the collector intact; and it carries
/// its own rate limit, because the server drops a repeat inside [waveCooldown] and a
/// mashed button should fall quiet here rather than fire a string of refusals the UI
/// would have to swallow. The wire shape itself — the action name Gather wants — is
/// unverified and lives in `direct_collector.dart`; this is about the app's half.
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

  test('forwards the target id to the collector', () async {
    final (:state, :collector) = wired();

    final failed = await state.sendWave('ada');

    expect(failed, isNull);
    expect(collector.waves, ['ada']);
  });

  test('swallows a repeat at the same person inside the cooldown', () async {
    final (:state, :collector) = wired();

    expect(await state.sendWave('ada'), isNull);
    // The second press lands well inside the 30s window: no refusal, and nothing
    // more on the wire.
    expect(await state.sendWave('ada'), isNull);

    expect(collector.waves, ['ada'], reason: 'the repeat is held back, not resent');
  });

  test('a different person is never held back by anothers cooldown', () async {
    final (:state, :collector) = wired();

    await state.sendWave('ada');
    final failed = await state.sendWave('bob');

    expect(failed, isNull);
    expect(collector.waves, ['ada', 'bob']);
  });

  test('says so, and sends nothing, when there is no collector', () async {
    final state = AppState();
    addTearDown(state.dispose);

    final failed = await state.sendWave('ada');

    expect(failed, contains('Not connected'));
  });

  test('an empty target is refused rather than sent', () async {
    final (:state, :collector) = wired();

    final failed = await state.sendWave('');

    expect(failed, isNotNull);
    expect(collector.waves, isEmpty);
  });
}
