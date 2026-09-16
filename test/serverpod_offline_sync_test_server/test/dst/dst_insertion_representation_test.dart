import 'package:serverpod_offline_sync_server/serverpod_offline_sync_server.dart';
import 'package:serverpod_offline_sync_test_client/serverpod_offline_sync_test_client.dart';
import 'package:test/test.dart';

import '../integration/test_tools/client_session.dart';
import 'framework/dst_random.dart';
import 'framework/dst_snapshot.dart';
import 'framework/dst_world.dart';

void main() {
  initTestClientSession(createSessionPerTest: false);
  for (final restore in [false, true]) {
    test(
      'Given a visible projected town ${restore ? 'restored with an older authored FK clock' : 'with a generation-one insertion marker'}, '
      'when a full-row upsert changes only its name, '
      'then authored FK preservation and canonical visibility remain valid.',
      () async {
        final ids = DstIds(DstRandom(81));
        final space = ids.next();
        final clock = DstClock();
        Future<DstReplica> replica(String name) => DstReplica.create(
          name: name,
          spaceUuids: [space],
          nodeUuid: ids.next(),
          clock: clock.clock,
        );
        final parentAuthor = await replica('parent');
        final receiver = await replica('receiver');
        final source = await replica('source');
        final mayor = Person(id: ids.next(), name: 'mayor');
        final town = Town(id: ids.next(), name: 'original', mayorId: mayor.id);
        await parentAuthor.withReplicaClock(
          () => parentAuthor.session.db.transactionForUser(
            space,
            (tx) => Person.db.insertRow(parentAuthor.session, mayor, transaction: tx),
          ),
        );
        await receiver.merge(await parentAuthor.collect(space), space);
        await source.merge(await parentAuthor.collect(space), space);
        await receiver.withReplicaClock(
          () => receiver.session.db.transactionForUser(
            space,
            (tx) => Town.db.insertRow(receiver.session, town, transaction: tx),
          ),
        );
        clock.advance(const Duration(milliseconds: 1));
        await source.withReplicaClock(
          () => source.session.db.transactionForUser(
            space,
            (tx) => source.session.db.upsertRow(
              town,
              conflictColumns: [Town.t.id],
              transaction: tx,
            ),
          ),
        );
        await receiver.merge(await source.collect(space), space);
        await parentAuthor.withReplicaClock(
          () => parentAuthor.session.db.transactionForUser(
            space,
            (tx) => Person.db.deleteRow(parentAuthor.session, mayor, transaction: tx),
          ),
        );
        await receiver.merge(await parentAuthor.collect(space), space);
        final projected = (await Town.db.findById(receiver.session, town.id!))!;
        expect(projected.mayorId, isNull);
        if (restore) {
          await receiver.withReplicaClock(
            () => receiver.session.db.transactionForUser(
              space,
              (tx) => Town.db.deleteRow(receiver.session, projected, transaction: tx),
            ),
          );
          await receiver.withReplicaClock(
            () => receiver.session.db.transactionForUser(
              space,
              (tx) => Town.db.insertRow(receiver.session, projected, transaction: tx),
            ),
          );
        }
        final before = await DstSnapshot.capture(receiver);
        final key = ('town', town.id!, 'mayorId');
        final rowKey = 'town/${town.id}';
        expect(before.tombstones[rowKey]!.clFlag, restore ? 3 : 1);
        expect(
          before.tombstones[rowKey]!.reason,
          restore
              ? CrdtDataDeletedReason.userReinsert
              : CrdtDataDeletedReason.userInsert,
        );
        if (restore) expect(before.fieldHlc(key)! < before.rowHlcs[rowKey]!, isTrue);
        final operations = DstOperations(DstRandom(82), ids);
        operations.oracle.accept(before);

        await operations.perform(
          receiver,
          space,
          table: DstTable.town,
          action: DstAction.upsert,
          body: (tx, evidence, refusal) async {
            final write = projected.copyWith(name: 'renamed');
            evidence.write('town', write.toJson());
            await receiver.session.db.upsertRow(
              write,
              conflictColumns: [Town.t.id],
              transaction: tx,
            );
            return DstOperationOutcome.applied;
          },
        );
        final after = await DstSnapshot.capture(receiver);

        expect(after.fieldHlc(key), before.fieldHlc(key));
        expect(after.authoredValue(key), mayor.id);
        expect(after.rowHlcs[rowKey], before.rowHlcs[rowKey]);
        expect(
          after.canonicalTombstone('town', town.id!),
          restore ? before.tombstones[rowKey] : null,
        );
        expect(operations.oracle.validate(after, space), isEmpty);
      },
    );
  }

  for (final upsert in [false, true]) {
    test(
      'Given a visible row with a projected unique text claim, '
      'when a full-row ${upsert ? 'upsert' : 'update'} changes only another column, '
      'then the preserved claim retains its authored value and field clock.',
      () async {
        final ids = DstIds(DstRandom(83));
        final space = ids.next();
        final replica = await DstReplica.create(
          name: 'replica',
          spaceUuids: [space],
          nodeUuid: ids.next(),
          clock: DstClock().clock,
        );
        final winner = UniqueOverlapping(
          id: ids.next(),
          first: 'a',
          second: 'b',
          third: 'c',
        );
        final loser = UniqueOverlapping(
          id: ids.next(),
          first: 'a',
          second: 'b',
          third: 'z',
        );
        for (final row in [winner, loser]) {
          await replica.withReplicaClock(
            () => replica.session.db.transactionForUser(
              space,
              (tx) => UniqueOverlapping.db.insertRow(
                replica.session,
                row,
                transaction: tx,
              ),
            ),
          );
        }
        final before = await DstSnapshot.capture(replica);
        final key = ('unique_overlapping', loser.id!, 'first');
        expect(before.projections[key]?.attemptedValue, 'a');
        final projected = (await UniqueOverlapping.db.findById(
          replica.session,
          loser.id!,
        ))!;
        expect(projected.first, isNot('a'));

        await replica.withReplicaClock(
          () => replica.session.db.transactionForUser(space, (tx) async {
            final write = projected.copyWith(third: 'renamed');
            if (upsert) {
              await replica.session.db.upsertRow(
                write,
                conflictColumns: [UniqueOverlapping.t.id],
                transaction: tx,
              );
            } else {
              await UniqueOverlapping.db.updateRow(
                replica.session,
                write,
                transaction: tx,
              );
            }
          }),
        );
        final after = await DstSnapshot.capture(replica);

        expect(
          after.rows['unique_overlapping']![loser.id]!.columns['third'],
          'renamed',
        );
        expect(after.authoredValue(key), 'a');
        expect(after.fieldHlc(key), before.fieldHlc(key));
      },
    );
  }
}
