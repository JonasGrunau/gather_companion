/// The pad is one pointer, and this is what that buys.
///
/// Four buttons would have been less code. The reason it is not four buttons is that
/// going round a corner would then mean lifting a thumb, finding the next button and
/// pressing again — a stutter at exactly the moment you are trying to steer. Every
/// test here is about the seam between "still the same press" and "a different
/// direction now", which is the part four buttons would have got for free and which
/// one [Listener] has to be shown to get right.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather_companion/theme/gather_theme.dart';
import 'package:gather_companion/ui/dpad.dart';

void main() {
  late List<String> pressed;
  late int released;

  setUp(() {
    pressed = [];
    released = 0;
  });

  Future<void> show(WidgetTester tester) => tester.pumpWidget(MaterialApp(
        theme: buildGatherTheme(),
        home: Scaffold(
          body: Center(
            child: DPad(onPress: pressed.add, onRelease: () => released++),
          ),
        ),
      ));

  /// Far enough from the middle to be past the hub whichever way it points.
  const reach = 60.0;

  testWidgets('a press names the arrow it landed on', (tester) async {
    await show(tester);
    final centre = tester.getCenter(find.byType(DPad));

    for (final (offset, direction) in [
      (const Offset(0, -reach), 'Up'),
      (const Offset(0, reach), 'Down'),
      (const Offset(-reach, 0), 'Left'),
      (const Offset(reach, 0), 'Right'),
    ]) {
      final gesture = await tester.startGesture(centre + offset);
      await tester.pump();
      expect(pressed.last, direction);
      await gesture.up();
      await tester.pump();
    }

    expect(pressed, ['Up', 'Down', 'Left', 'Right']);
    expect(released, 4);
  });

  testWidgets('sliding to another arrow turns without letting go', (tester) async {
    await show(tester);
    final centre = tester.getCenter(find.byType(DPad));

    final gesture = await tester.startGesture(centre + const Offset(0, -reach));
    await tester.pump();
    await gesture.moveTo(centre + const Offset(reach, 0));
    await tester.pump();

    expect(pressed, ['Up', 'Right']);
    expect(released, 0, reason: 'the walk never stopped');

    await gesture.up();
    await tester.pump();
    expect(released, 1);
  });

  testWidgets('a thumb jittering on one arrow is one press', (tester) async {
    // Pointer moves arrive many times a frame. Reporting each one would ask the walk
    // to restart at the rate the finger shakes.
    await show(tester);
    final centre = tester.getCenter(find.byType(DPad));

    final gesture = await tester.startGesture(centre + const Offset(4, -reach));
    await tester.pump();
    await gesture.moveTo(centre + const Offset(-6, -reach + 3));
    await tester.pump();
    await gesture.moveTo(centre + const Offset(2, -reach - 8));
    await tester.pump();

    expect(pressed, ['Up']);
    await gesture.up();
  });

  testWidgets('sliding back to the middle stops without lifting', (tester) async {
    // The dead zone is the whole reason a thumb can stop the walk exactly where it
    // wants to: lifting is a coarser instrument, because the last arrow you cross on
    // the way up gets a step out of you.
    await show(tester);
    final centre = tester.getCenter(find.byType(DPad));

    final gesture = await tester.startGesture(centre + const Offset(reach, 0));
    await tester.pump();
    await gesture.moveTo(centre);
    await tester.pump();

    expect(pressed, ['Right']);
    expect(released, 1);

    // And it is still the same press, so sliding back out walks again.
    await gesture.moveTo(centre + const Offset(0, reach));
    await tester.pump();
    expect(pressed, ['Right', 'Down']);

    await gesture.up();
    await tester.pump();
    expect(released, 2);
  });

  testWidgets('a press that starts in the middle walks nowhere', (tester) async {
    await show(tester);
    final gesture = await tester.startGesture(tester.getCenter(find.byType(DPad)));
    await tester.pump();

    expect(pressed, isEmpty);
    expect(released, 0, reason: 'nothing was held, so nothing was let go of');

    await gesture.up();
    await tester.pump();
    expect(released, 0);
  });

  testWidgets('a cancelled pointer lets go', (tester) async {
    // A system gesture can take the pointer away mid-press and never send an up. The
    // walk has to end on that, or the avatar keeps going.
    await show(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(DPad)) + const Offset(reach, 0),
    );
    await tester.pump();
    await gesture.cancel();
    await tester.pump();

    expect(released, 1);
  });

  testWidgets('the quarters are split on the diagonals', (tester) async {
    // The hit test and the painter have to agree about where one quarter ends and the
    // next begins, or there is a band near every diagonal where what you press is not
    // what lights up. Both use |dx| > |dy|, so a point just either side of the corner
    // belongs to the two different quarters it looks like it should.
    await show(tester);
    final centre = tester.getCenter(find.byType(DPad));

    for (final (offset, direction) in [
      (const Offset(reach, -reach + 6), 'Right'),
      (const Offset(reach - 6, -reach), 'Up'),
      (const Offset(-reach, reach - 6), 'Left'),
      (const Offset(-reach + 6, reach), 'Down'),
    ]) {
      final gesture = await tester.startGesture(centre + offset);
      await tester.pump();
      expect(pressed.last, direction, reason: '$offset');
      await gesture.up();
      await tester.pump();
    }
  });

  testWidgets('each arrow is a button a screen reader can take', (tester) async {
    // The gesture above is unreachable with VoiceOver on, so the four arrows carry
    // their own semantics. A tap there is one step, because a semantic tap cannot be
    // held and pretending otherwise would start a walk nothing ends.
    final handle = tester.ensureSemantics();
    await show(tester);

    for (final direction in ['up', 'down', 'left', 'right']) {
      expect(find.bySemanticsLabel('Walk $direction'), findsOneWidget);
    }

    tester.semantics.tap(find.semantics.byLabel('Walk up'));
    await tester.pump();

    expect(pressed, ['Up']);
    expect(released, 1, reason: 'one step, and it lets go of it');
    handle.dispose();
  });
}
