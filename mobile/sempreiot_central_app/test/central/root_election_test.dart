import 'package:flutter_test/flutter_test.dart';
import 'package:sempreiot_central_app/features/central/application/root_election_provider.dart';

void main() {
  final t0 = DateTime.utc(2026, 9, 27, 12, 0, 0);
  DateTime at(int s) => t0.add(Duration(seconds: s));
  const a = 'AA:00:00:00:00:01', b = 'AA:00:00:00:00:02';

  RootElectionState run(RootElectionState s, List<(int, Set<String>)> steps) {
    for (final (sec, cands) in steps) {
      s = stepRootElection(s, cands, at(sec));
    }
    return s;
  }

  group('root election', () {
    test('a fresh start with one unit settles silently after 3 s', () {
      var s = run(RootElectionState.none, [(0, {a}), (1, {a}), (2, {a})]);
      expect(s.rootMac, isNull);
      expect(s.electing, isFalse, reason: 'no election is declared on start');
      s = stepRootElection(s, {a}, at(3));
      expect(s.rootMac, a);
      expect(s.electing, isFalse);
    });

    test('empty mesh with no root ever known is not an election', () {
      final s = run(RootElectionState.none, [(0, {}), (5, {})]);
      expect(s.electing, isFalse);
      expect(s.rootMac, isNull);
    });

    test('root lost -> electing; two candidates stay electing', () {
      var s = run(RootElectionState.none, [(0, {a}), (3, {a})]);
      expect(s.rootMac, a);
      s = stepRootElection(s, {}, at(10)); // dead root gone from the map
      expect(s.electing, isTrue);
      expect(s.electingSince, at(10));
      expect(s.rootMac, isNull);
      s = stepRootElection(s, {a, b}, at(16)); // both survivors at level 1
      expect(s.electing, isTrue);
      expect(s.candidates, {a, b});
      expect(s.electingSince, at(10), reason: 'one election, one start time');
    });

    test('the sole survivor earns the badge only after 3 s alone', () {
      var s = run(RootElectionState.none, [(0, {a}), (3, {a}), (10, {}), (16, {a, b})]);
      s = stepRootElection(s, {b}, at(20)); // a backed off
      expect(s.electing, isTrue);
      expect(s.rootMac, isNull);
      s = stepRootElection(s, {b}, at(22));
      expect(s.rootMac, isNull, reason: 'only 2 s alone');
      s = stepRootElection(s, {b}, at(23));
      expect(s.rootMac, b);
      expect(s.electing, isFalse);
    });

    test('a candidate that flips back resets its settle timer', () {
      var s = run(RootElectionState.none, [(0, {a}), (3, {a}), (10, {a, b})]);
      s = stepRootElection(s, {b}, at(11));
      s = stepRootElection(s, {a, b}, at(12));
      s = stepRootElection(s, {b}, at(13));
      s = stepRootElection(s, {b}, at(15));
      expect(s.rootMac, isNull, reason: 'alone since 13, not since 11');
      s = stepRootElection(s, {b}, at(16));
      expect(s.rootMac, b);
    });

    test('a known root staying alone never re-elects', () {
      final s = run(RootElectionState.none, [(0, {a}), (3, {a}), (60, {a}), (600, {a})]);
      expect(s.rootMac, a);
      expect(s.electing, isFalse);
    });

    test('overdue after 30 s without a settled root', () {
      var s = run(RootElectionState.none, [(0, {a}), (3, {a}), (10, {})]);
      expect(s.overdue(at(39)), isFalse);
      expect(s.overdue(at(41)), isTrue);
    });
  });
}
