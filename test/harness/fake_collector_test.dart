import 'package:flutter_test/flutter_test.dart';
import 'package:gather_client/gather_client.dart';

import 'package:gather_companion/harness/fake_collector.dart';
import 'package:gather_companion/harness/harness_data.dart';

RosterRow _self(Roster roster) => roster.rows.firstWhere((r) => r.id == kSelfId);

void main() {
  group('FakeCollector', () {
    test('start() emits a healthy status and a roster with me and the cast', () async {
      final fake = FakeCollector(participants: 3);
      addTearDown(fake.dispose);

      final rosters = <Roster>[];
      final statuses = <CollectorStatus>[];
      fake.rosters.listen(rosters.add);
      fake.statuses.listen(statuses.add);

      fake.start();
      await Future<void>.delayed(Duration.zero);

      expect(statuses.single.healthy, isTrue);
      final roster = rosters.single;
      // me + three colleagues.
      expect(roster.rows.length, 4);
      expect(roster.selfId, kSelfId);
      final me = _self(roster);
      expect(me.x, kSelfStartTile.x);
      expect(me.y, kSelfStartTile.y);
      // The cast are present, or peopleOnMap would drop them.
      final other = roster.rows.firstWhere((r) => r.id != kSelfId);
      expect(other.isPresent, isTrue);
    });

    test('move re-emits a roster with my tile advanced — the server echo', () async {
      final fake = FakeCollector(participants: 1);
      addTearDown(fake.dispose);

      final rosters = <Roster>[];
      fake.rosters.listen(rosters.add);
      fake.start();
      await Future<void>.delayed(Duration.zero);

      final before = _self(rosters.last);
      final r = fake.move(direction: 'Right');
      await Future<void>.delayed(Duration.zero);

      expect(r.ok, isTrue);
      final after = _self(rosters.last);
      expect(after.x, (before.x ?? 0) + 1);
      expect(after.y, before.y);
      expect(after.direction, 'Right');
    });

    test('teleport moves me to the tile and re-emits', () async {
      final fake = FakeCollector(participants: 1);
      addTearDown(fake.dispose);

      final rosters = <Roster>[];
      fake.rosters.listen(rosters.add);
      fake.start();

      final r = fake.teleport(x: 2, y: 3);
      await Future<void>.delayed(Duration.zero);

      expect(r.ok, isTrue);
      final me = _self(rosters.last);
      expect(me.x, 2);
      expect(me.y, 3);
    });

    test('wave lands a WaveEvent aimed at me on the interactions bus', () async {
      final fake = FakeCollector(participants: 1);
      addTearDown(fake.dispose);

      final events = <BusEvent>[];
      fake.interactions.listen(events.add);
      fake.start();

      fake.injectWave('space-ada');
      await Future<void>.delayed(Duration.zero);

      expect(events.single.name, 'WaveEvent');
      expect(events.single.senderId, 'space-ada');
      expect(events.single.isFor(kSelfId), isTrue);
    });
  });
}
