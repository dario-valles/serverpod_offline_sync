import 'package:serverpod_offline_sync_test_client/serverpod_offline_sync_test_client.dart';
import 'package:test/test.dart';

import '../integration/test_tools/client_session.dart';
import 'framework/dst_random.dart';
import 'framework/dst_roundtrip.dart';
import 'framework/dst_snapshot.dart';
import 'framework/dst_world.dart';

void main() {
  initTestClientSession(createSessionPerTest: false);

  for (final crossSpace in [false, true]) {
    test(
      'Given a detector snapshot whose town references a mayor in ${crossSpace ? 'another' : 'the same'} space, '
      'when the ownership oracle checks the reference, '
      'then it ${crossSpace ? 'rejects the cross-space link' : 'accepts the space-local link'}.',
      () {
        final ids = DstIds(DstRandom(92));
        final space = ids.next();
        final parentSpace = crossSpace ? ids.next() : space;
        final parent = ids.next();
        final child = ids.next();
        // Detector fault injection only; the invalid link is never written to
        // a database or submitted as a supposedly valid production merge.
        final snapshot = DstSnapshot(
          rows: {
            'person': {
              parent: (
                spaceUuid: parentSpace,
                columns: {'id': parent.toString()},
                visible: true,
              ),
            },
            'town': {
              child: (
                spaceUuid: space,
                columns: {'id': child.toString(), 'mayorId': parent.toString()},
                visible: true,
              ),
            },
          },
          projections: {},
          causalLengths: {},
        );

        final violations = DstOracle.noCrossSpaceLink(snapshot);

        expect(
          violations.map((v) => v.property),
          crossSpace ? ['noCrossSpaceLink'] : isEmpty,
        );
      },
    );
  }

  for (final diverged in [false, true]) {
    test(
      'Given replicas with unequal subscriptions and ${diverged ? 'different' : 'identical'} facts in their shared space, '
      'when the observer-independence oracle compares them, '
      'then it ${diverged ? 'reports the shared-space disagreement' : 'ignores facts belonging only to the other space'}.',
      () async {
        final ids = DstIds(DstRandom(93));
        final space = ids.next();
        final otherSpace = ids.next();
        final clock = DstClock();
        final left = await _replica(ids, clock, 'left', [space]);
        final right = await _replica(ids, clock, 'right', [space, otherSpace]);
        final city = City(id: ids.next(), name: 'shared');
        await left.withReplicaClock(
          () => left.session.db.transactionForUser(
            space,
            (tx) => City.db.insertRow(left.session, city, transaction: tx),
          ),
        );
        await right.merge(await left.collect(space), space);
        await right.withReplicaClock(
          () => right.session.db.transactionForUser(
            otherSpace,
            (tx) => City.db.insertRow(
              right.session,
              City(id: ids.next(), name: 'other-space-only'),
              transaction: tx,
            ),
          ),
        );
        if (diverged) {
          await right.withReplicaClock(
            () => right.session.db.transactionForUser(
              space,
              (tx) => City.db.updateRow(
                right.session,
                city.copyWith(name: 'unshared update'),
                columns: (t) => [t.name],
                transaction: tx,
              ),
            ),
          );
        }

        final violations = DstOracle.observerIndependence({
          left: await DstSnapshot.capture(left),
          right: await DstSnapshot.capture(right),
        }, space);

        expect(
          violations.map((v) => v.property),
          diverged ? ['observerIndependence'] : isEmpty,
        );
      },
    );
  }

  for (final next in [null, 1, 3, 4]) {
    final change = switch (next) {
      null => 'omits that generation',
      1 => 'regresses to generation 1',
      3 => 'repeats generation 3',
      _ => 'advances to generation 4',
    };
    final rejected = next == null || next < 3;
    test(
      'Given an observed restore generation of 3, '
      'when a later detector snapshot $change, '
      'then the causal-length oracle ${rejected ? 'reports lost progress' : 'accepts monotonic progress'}.',
      () {
        final key = 'city/${DstIds(DstRandom(94)).next()}';
        DstSnapshot snapshot(Map<String, int> flags) => DstSnapshot(
          rows: {},
          projections: {},
          causalLengths: flags,
        );
        final oracle = DstCausalLength();
        expect(oracle.observe('replica', snapshot({key: 3})), isEmpty);

        final violations = oracle.observe(
          'replica',
          snapshot({key: ?next}),
        );

        expect(
          violations.map((v) => v.property),
          rejected ? ['causalLength'] : isEmpty,
        );
      },
    );
  }

  for (final missingCity in [false, true]) {
    test(
      'Given an expected snapshot ${missingCity ? 'including a later city absent from the source' : 'matching the source'}, '
      'when an empty replica receives the complete source export, '
      'then the round-trip detector ${missingCity ? 'reports the missing accepted city' : 'accepts the complete facts'}.',
      () async {
        final ids = DstIds(DstRandom(95));
        final space = ids.next();
        final clock = DstClock();
        final source = await _replica(ids, clock, 'source', [space]);
        final accepted = await _replica(ids, clock, 'accepted', [space]);
        await source.withReplicaClock(
          () => source.session.db.transactionForUser(
            space,
            (tx) => City.db.insertRow(
              source.session,
              City(id: ids.next(), name: 'first'),
              transaction: tx,
            ),
          ),
        );
        await accepted.merge(await source.collect(space), space);
        if (missingCity) {
          await accepted.withReplicaClock(
            () => accepted.session.db.transactionForUser(
              space,
              (tx) => City.db.insertRow(
                accepted.session,
                City(id: ids.next(), name: 'missing accepted city'),
                transaction: tx,
              ),
            ),
          );
        }
        // Both states and the collected batch are real and causally complete.
        // Supplying the newer accepted snapshot is detector fault injection
        // modelling an export omission, not an invalid split merge batch.
        final expected = await DstSnapshot.capture(accepted);

        final violations = await exportRoundTrip(
          source: source,
          expected: expected,
          ids: ids,
          clock: clock.clock,
        );

        expect(
          violations.map((v) => v.property),
          missingCity ? ['exportRoundTrip'] : isEmpty,
        );
        if (missingCity) {
          expect(violations.single.detail, contains('missing accepted city'));
        }
      },
    );
  }
}

Future<DstReplica> _replica(
  DstIds ids,
  DstClock clock,
  String name,
  List<UuidValue> spaces,
) => DstReplica.create(
  name: name,
  spaceUuids: spaces,
  nodeUuid: ids.next(),
  clock: clock.clock,
);
