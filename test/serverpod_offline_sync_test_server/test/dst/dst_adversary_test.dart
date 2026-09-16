import 'package:serverpod_offline_sync_test_client/serverpod_offline_sync_test_client.dart';
import 'package:test/test.dart';

import '../integration/test_tools/client_session.dart';
import 'framework/dst_adversary.dart';
import 'framework/dst_random.dart';
import 'framework/dst_snapshot.dart';
import 'framework/dst_world.dart';

void main() {
  initTestClientSession(createSessionPerTest: false);

  test(
    'Given two replicas and a schedule repeatedly redelivering one city insertion, '
    'when the network drains after those duplicate deliveries, '
    'then stable authored facts converge without a false non-idempotence failure.',
    () async {
      final ids = DstIds(DstRandom(916));
      final space = ids.next();
      final clock = DstClock();
      final replicas = <DstReplica>[];
      for (var index = 0; index < 2; index++) {
        replicas.add(
          await DstReplica.create(
            name: 'r$index',
            spaceUuids: [space],
            nodeUuid: ids.next(),
            clock: clock.clock,
          ),
        );
      }
      final author = replicas.first;
      await author.withReplicaClock(
        () => author.session.db.transactionForUser(
          space,
          (tx) => City.db.insertRow(
            author.session,
            City(id: ids.next(), name: 'city'),
            transaction: tx,
          ),
        ),
      );
      final expected = (await DstSnapshot.capture(author)).renderSpace(space);
      final adversary = DstAdversary(_RepeatedDeliverySchedule(), replicas);
      Future<void> check(DstReplica replica) async {
        expect(DstOracle.invariants(await DstSnapshot.capture(replica)), isEmpty);
      }

      await adversary.step(check);
      await adversary.step(check);
      expect(adversary.duplicateBatches, greaterThan(0));
      await adversary.quiesce(check);

      for (final replica in replicas) {
        expect((await DstSnapshot.capture(replica)).renderSpace(space), expected);
      }
    },
  );
}

/// A concrete network schedule: always collect the first replica, always
/// choose resend, and never isolate delivery. Database/merge paths stay real.
class _RepeatedDeliverySchedule extends DstRandom {
  _RepeatedDeliverySchedule() : super(916);

  @override
  bool chance(double probability) => probability != 0.2;

  @override
  T pick<T>(List<T> items) => items.first;
}
