import 'package:serverpod_offline_sync_server/serverpod_offline_sync_server.dart';
import 'package:serverpod_offline_sync_test_client/serverpod_offline_sync_test_client.dart';
import 'package:test/test.dart';

import '../integration/test_tools/client_session.dart';
import 'framework/dst_random.dart';
import 'framework/dst_snapshot.dart';
import 'framework/dst_world.dart';

void main() {
  initTestClientSession(createSessionPerTest: false);

  group('Given a unique winner and a later independently authored competing claim, ', () {
    late UuidValue space;
    late DstReplica replica;
    late DstOperations operations;
    late UniqueOverlapping winner;
    late UniqueOverlapping competitor;
    late DstFieldKey claimKey;
    late DstSnapshot before;

    setUp(() async {
      final random = DstRandom(85);
      final ids = DstIds(random);
      space = ids.next();
      replica = await DstReplica.create(
        name: 'winner',
        spaceUuids: [space],
        nodeUuid: ids.next(),
        clock: DstClock().clock,
      );
      final peer = await DstReplica.create(
        name: 'competitor',
        spaceUuids: [space],
        nodeUuid: ids.next(),
        clock: DstClock().skewed(const Duration(milliseconds: 1)),
      );
      winner = UniqueOverlapping(id: ids.next(), first: 'a', second: 'b', third: 'c');
      competitor = UniqueOverlapping(
        id: ids.next(),
        first: 'a',
        second: 'b',
        third: 'z',
      );
      await replica.withReplicaClock(
        () => replica.session.db.transactionForUser(
          space,
          (tx) =>
              UniqueOverlapping.db.insertRow(replica.session, winner, transaction: tx),
        ),
      );
      await peer.withReplicaClock(
        () => peer.session.db.transactionForUser(
          space,
          (tx) =>
              UniqueOverlapping.db.insertRow(peer.session, competitor, transaction: tx),
        ),
      );
      await replica.merge(await peer.collect(space), space);
      before = await DstSnapshot.capture(replica);
      claimKey = ('unique_overlapping', winner.id!, 'first');
      expect(before.visible['unique_overlapping']![winner.id]!.columns['first'], 'a');
      operations = DstOperations(random, ids);
      operations.oracle.accept(before);
    });

    group('when the winner edits its third value in a full-row save, ', () {
      late DstSnapshot after;

      setUp(() async {
        await operations.perform(
          replica,
          space,
          table: DstTable.uniqueOverlapping,
          action: DstAction.fullRowUpdate,
          body: (tx, evidence, refusal) async {
            final write = winner.copyWith(third: 'edited');
            evidence.write('unique_overlapping', write.toJson());
            await UniqueOverlapping.db.updateRow(
              replica.session,
              write,
              transaction: tx,
            );
            return DstOperationOutcome.applied;
          },
        );
        after = await DstSnapshot.capture(replica);
      });

      test(
        'then its touched claim becomes newer and the competing record displays the name.',
        () {
          expect(after.fieldHlc(claimKey), greaterThan(before.fieldHlc(claimKey)!));
          expect(after.authoredValue(claimKey), 'a');
          expect(
            after.visible['unique_overlapping']![winner.id]!.columns['first'],
            'a__conflict__${winner.id}',
          );
          expect(
            after.visible['unique_overlapping']![competitor.id]!.columns['first'],
            'a',
          );
          expect(
            after.visible['unique_overlapping']![winner.id]!.columns['third'],
            'edited',
          );
          expect(operations.validationFailures, 0);
        },
      );
    });

    group('when the winner edits only its selected third column, ', () {
      late DstSnapshot after;

      setUp(() async {
        await operations.perform(
          replica,
          space,
          table: DstTable.uniqueOverlapping,
          action: DstAction.update,
          body: (tx, evidence, refusal) async {
            final write = winner.copyWith(third: 'edited');
            evidence.write('unique_overlapping', write.toJson(), columns: {'third'});
            await UniqueOverlapping.db.updateRow(
              replica.session,
              write,
              columns: (t) => [t.third],
              transaction: tx,
            );
            return DstOperationOutcome.applied;
          },
        );
        after = await DstSnapshot.capture(replica);
      });

      test('then its excluded claim keeps its age and still displays the name.', () {
        expect(after.fieldHlc(claimKey), before.fieldHlc(claimKey));
        expect(after.authoredValue(claimKey), 'a');
        expect(after.visible['unique_overlapping']![winner.id]!.columns['first'], 'a');
        expect(
          after.visible['unique_overlapping']![competitor.id]!.columns['first'],
          'a__conflict__${competitor.id}',
        );
        expect(
          after.visible['unique_overlapping']![winner.id]!.columns['third'],
          'edited',
        );
        expect(operations.validationFailures, 0);
      });
    });
  });

  group('Given a visible projected town with a generation-one insertion marker, ', () {
    late UuidValue space;
    late DstReplica receiver;
    late Person mayor;
    late Town town;
    late Town projected;
    late DstSnapshot before;
    late DstFieldKey key;
    late String rowKey;
    late DstOperations operations;

    setUpAll(() async {
      final ids = DstIds(DstRandom(81));
      space = ids.next();
      final clock = DstClock();
      Future<DstReplica> replica(String name) => DstReplica.create(
        name: name,
        spaceUuids: [space],
        nodeUuid: ids.next(),
        clock: clock.clock,
      );
      final parentAuthor = await replica('parent');
      receiver = await replica('receiver');
      final source = await replica('source');
      mayor = Person(id: ids.next(), name: 'mayor');
      town = Town(id: ids.next(), name: 'original', mayorId: mayor.id);
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
      projected = (await Town.db.findById(receiver.session, town.id!))!;
      expect(projected.mayorId, isNull);
      before = await DstSnapshot.capture(receiver);
      key = ('town', town.id!, 'mayorId');
      rowKey = 'town/${town.id}';
      expect(before.tombstones[rowKey]!.clFlag, 1);
      expect(
        before.tombstones[rowKey]!.reason,
        CrdtDataDeletedReason.userInsert,
      );

      operations = DstOperations(DstRandom(82), ids);
      operations.oracle.accept(before);
    });

    group('when a full-row upsert changes only its name, ', () {
      late DstSnapshot after;

      setUpAll(() async {
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
        after = await DstSnapshot.capture(receiver);
      });

      test('then authored FK preservation and canonical visibility remain valid.', () {
        expect(after.fieldHlc(key), before.fieldHlc(key));
        expect(after.authoredValue(key), mayor.id);
        expect(after.rowHlcs[rowKey], before.rowHlcs[rowKey]);
        expect(
          after.canonicalTombstone('town', town.id!),
          null,
        );
        expect(operations.oracle.validate(after, space), isEmpty);
      });
    });
  });

  group(
    'Given a visible projected town restored with a renewed authored FK clock, ',
    () {
      late UuidValue space;
      late DstReplica receiver;
      late Person mayor;
      late Town town;
      late Town projected;
      late DstSnapshot before;
      late DstFieldKey key;
      late String rowKey;
      late DstOperations operations;

      setUpAll(() async {
        final ids = DstIds(DstRandom(81));
        space = ids.next();
        final clock = DstClock();
        Future<DstReplica> replica(String name) => DstReplica.create(
          name: name,
          spaceUuids: [space],
          nodeUuid: ids.next(),
          clock: clock.clock,
        );
        final parentAuthor = await replica('parent');
        receiver = await replica('receiver');
        final source = await replica('source');
        mayor = Person(id: ids.next(), name: 'mayor');
        town = Town(id: ids.next(), name: 'original', mayorId: mayor.id);
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
        projected = (await Town.db.findById(receiver.session, town.id!))!;
        expect(projected.mayorId, isNull);
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
        before = await DstSnapshot.capture(receiver);
        key = ('town', town.id!, 'mayorId');
        rowKey = 'town/${town.id}';
        expect(before.tombstones[rowKey]!.clFlag, 3);
        expect(
          before.tombstones[rowKey]!.reason,
          CrdtDataDeletedReason.userReinsert,
        );
        expect(before.fieldHlc(key), before.rowHlcs[rowKey]);
        operations = DstOperations(DstRandom(82), ids);
        operations.oracle.accept(before);
      });

      group('when a full-row upsert changes only its name, ', () {
        late DstSnapshot after;

        setUpAll(() async {
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
          after = await DstSnapshot.capture(receiver);
        });

        test(
          'then authored FK preservation and canonical visibility remain valid.',
          () {
            expect(after.fieldHlc(key), before.fieldHlc(key));
            expect(after.authoredValue(key), mayor.id);
            expect(after.rowHlcs[rowKey], before.rowHlcs[rowKey]);
            expect(
              after.canonicalTombstone('town', town.id!),
              before.tombstones[rowKey],
            );
            expect(operations.oracle.validate(after, space), isEmpty);
          },
        );
      });
    },
  );

  group('Given a visible row with a projected unique text claim, ', () {
    late UuidValue space;
    late DstReplica replica;
    late UniqueOverlapping loser;
    late UniqueOverlapping projected;
    late DstSnapshot before;
    late DstFieldKey firstKey;
    late DstFieldKey secondKey;
    late DstFieldKey thirdKey;
    late DstOperations operations;

    setUp(() async {
      final ids = DstIds(DstRandom(83));
      space = ids.next();
      replica = await DstReplica.create(
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
      loser = UniqueOverlapping(
        id: ids.next(),
        first: 'a',
        second: 'b',
        third: 'z',
      );
      await replica.withReplicaClock(
        () => replica.session.db.transactionForUser(
          space,
          (tx) =>
              UniqueOverlapping.db.insertRow(replica.session, winner, transaction: tx),
        ),
      );
      final peer = await DstReplica.create(
        name: 'independent-claim',
        spaceUuids: [space],
        nodeUuid: ids.next(),
        clock: DstClock().skewed(const Duration(milliseconds: 1)),
      );
      await peer.withReplicaClock(
        () => peer.session.db.transactionForUser(
          space,
          (tx) => UniqueOverlapping.db.insertRow(peer.session, loser, transaction: tx),
        ),
      );
      await replica.merge(await peer.collect(space), space);
      before = await DstSnapshot.capture(replica);
      firstKey = ('unique_overlapping', loser.id!, 'first');
      secondKey = ('unique_overlapping', loser.id!, 'second');
      thirdKey = ('unique_overlapping', loser.id!, 'third');
      expect(before.projections[firstKey]?.attemptedValue, 'a');
      projected = (await UniqueOverlapping.db.findById(replica.session, loser.id!))!;
      expect(projected.first, isNot('a'));
      operations = DstOperations(DstRandom(84), ids);
      operations.oracle.accept(before);
    });

    group('when an update changes its third value without a column filter, ', () {
      late DstSnapshot after;

      setUp(() async {
        await operations.perform(
          replica,
          space,
          table: DstTable.uniqueOverlapping,
          action: DstAction.fullRowUpdate,
          body: (tx, evidence, refusal) async {
            final write = projected.copyWith(third: 'renamed');
            evidence.write('unique_overlapping', write.toJson());
            await UniqueOverlapping.db.updateRow(
              replica.session,
              write,
              transaction: tx,
            );
            return DstOperationOutcome.applied;
          },
        );
        after = await DstSnapshot.capture(replica);
      });

      test(
        'then every field clock advances while the preserved claim stays intact.',
        () {
          expect(
            after.rows['unique_overlapping']![loser.id]!.columns['third'],
            'renamed',
          );
          expect(after.authoredValue(firstKey), 'a');
          expect(after.authoredValue(secondKey), 'b');
          expect(after.fieldHlc(firstKey), greaterThan(before.fieldHlc(firstKey)!));
          expect(after.fieldHlc(secondKey), greaterThan(before.fieldHlc(secondKey)!));
          expect(after.fieldHlc(thirdKey), greaterThan(before.fieldHlc(thirdKey)!));
          expect(operations.committed, 1);
          expect(operations.validationFailures, 0);
          expect(operations.oracle.validate(after, space), isEmpty);
        },
      );
    });

    group(
      'when an update changes its third value with only the third column selected, ',
      () {
        late DstSnapshot after;

        setUp(() async {
          await operations.perform(
            replica,
            space,
            table: DstTable.uniqueOverlapping,
            action: DstAction.update,
            body: (tx, evidence, refusal) async {
              final write = projected.copyWith(third: 'renamed');
              evidence.write('unique_overlapping', write.toJson(), columns: {'third'});
              await UniqueOverlapping.db.updateRow(
                replica.session,
                write,
                columns: (t) => [t.third],
                transaction: tx,
              );
              return DstOperationOutcome.applied;
            },
          );
          after = await DstSnapshot.capture(replica);
        });

        test(
          'then only the third field clock advances while the preserved claim stays intact.',
          () {
            expect(
              after.rows['unique_overlapping']![loser.id]!.columns['third'],
              'renamed',
            );
            expect(after.authoredValue(firstKey), 'a');
            expect(after.authoredValue(secondKey), 'b');
            expect(after.fieldHlc(firstKey), before.fieldHlc(firstKey));
            expect(after.fieldHlc(secondKey), before.fieldHlc(secondKey));
            expect(after.fieldHlc(thirdKey), greaterThan(before.fieldHlc(thirdKey)!));
            expect(operations.committed, 1);
            expect(operations.validationFailures, 0);
            expect(operations.oracle.validate(after, space), isEmpty);
          },
        );
      },
    );

    group(
      'when an update changes its third value with the unchanged second column also selected, ',
      () {
        late DstSnapshot after;

        setUp(() async {
          await operations.perform(
            replica,
            space,
            table: DstTable.uniqueOverlapping,
            action: DstAction.update,
            body: (tx, evidence, refusal) async {
              final write = projected.copyWith(third: 'renamed');
              evidence.write(
                'unique_overlapping',
                write.toJson(),
                columns: {'second', 'third'},
              );
              await UniqueOverlapping.db.updateRow(
                replica.session,
                write,
                columns: (t) => [t.second, t.third],
                transaction: tx,
              );
              return DstOperationOutcome.applied;
            },
          );
          after = await DstSnapshot.capture(replica);
        });

        test(
          'then the second and third field clocks advance while the unselected claim stays intact.',
          () {
            expect(
              after.rows['unique_overlapping']![loser.id]!.columns['third'],
              'renamed',
            );
            expect(after.authoredValue(firstKey), 'a');
            expect(after.authoredValue(secondKey), 'b');
            expect(after.fieldHlc(firstKey), before.fieldHlc(firstKey));
            expect(after.fieldHlc(secondKey), greaterThan(before.fieldHlc(secondKey)!));
            expect(after.fieldHlc(thirdKey), greaterThan(before.fieldHlc(thirdKey)!));
            expect(operations.committed, 1);
            expect(operations.validationFailures, 0);
            expect(operations.oracle.validate(after, space), isEmpty);
          },
        );
      },
    );

    group('when an upsert changes its third value without a column filter, ', () {
      late DstSnapshot after;

      setUp(() async {
        await operations.perform(
          replica,
          space,
          table: DstTable.uniqueOverlapping,
          action: DstAction.upsert,
          body: (tx, evidence, refusal) async {
            final write = projected.copyWith(third: 'renamed');
            evidence.write('unique_overlapping', write.toJson());
            await replica.session.db.upsertRow(
              write,
              conflictColumns: [UniqueOverlapping.t.id],
              transaction: tx,
            );
            return DstOperationOutcome.applied;
          },
        );
        after = await DstSnapshot.capture(replica);
      });

      test(
        'then every field clock advances while the preserved claim stays intact.',
        () {
          expect(
            after.rows['unique_overlapping']![loser.id]!.columns['third'],
            'renamed',
          );
          expect(after.authoredValue(firstKey), 'a');
          expect(after.authoredValue(secondKey), 'b');
          expect(after.fieldHlc(firstKey), greaterThan(before.fieldHlc(firstKey)!));
          expect(after.fieldHlc(secondKey), greaterThan(before.fieldHlc(secondKey)!));
          expect(after.fieldHlc(thirdKey), greaterThan(before.fieldHlc(thirdKey)!));
          expect(operations.committed, 1);
          expect(operations.validationFailures, 0);
          expect(operations.oracle.validate(after, space), isEmpty);
        },
      );
    });

    group(
      'when an upsert changes its third value with only the third column selected, ',
      () {
        late DstSnapshot after;

        setUp(() async {
          await operations.perform(
            replica,
            space,
            table: DstTable.uniqueOverlapping,
            action: DstAction.upsert,
            body: (tx, evidence, refusal) async {
              final write = projected.copyWith(third: 'renamed');
              evidence.write('unique_overlapping', write.toJson(), columns: {'third'});
              await replica.session.db.upsertRow(
                write,
                conflictColumns: [UniqueOverlapping.t.id],
                updateColumns: [UniqueOverlapping.t.third],
                transaction: tx,
              );
              return DstOperationOutcome.applied;
            },
          );
          after = await DstSnapshot.capture(replica);
        });

        test(
          'then only the third field clock advances while the preserved claim stays intact.',
          () {
            expect(
              after.rows['unique_overlapping']![loser.id]!.columns['third'],
              'renamed',
            );
            expect(after.authoredValue(firstKey), 'a');
            expect(after.authoredValue(secondKey), 'b');
            expect(after.fieldHlc(firstKey), before.fieldHlc(firstKey));
            expect(after.fieldHlc(secondKey), before.fieldHlc(secondKey));
            expect(after.fieldHlc(thirdKey), greaterThan(before.fieldHlc(thirdKey)!));
            expect(operations.committed, 1);
            expect(operations.validationFailures, 0);
            expect(operations.oracle.validate(after, space), isEmpty);
          },
        );
      },
    );

    group(
      'when an upsert changes its third value with the unchanged second column also selected, ',
      () {
        late DstSnapshot after;

        setUp(() async {
          await operations.perform(
            replica,
            space,
            table: DstTable.uniqueOverlapping,
            action: DstAction.upsert,
            body: (tx, evidence, refusal) async {
              final write = projected.copyWith(third: 'renamed');
              evidence.write(
                'unique_overlapping',
                write.toJson(),
                columns: {'second', 'third'},
              );
              await replica.session.db.upsertRow(
                write,
                conflictColumns: [UniqueOverlapping.t.id],
                updateColumns: [UniqueOverlapping.t.second, UniqueOverlapping.t.third],
                transaction: tx,
              );
              return DstOperationOutcome.applied;
            },
          );
          after = await DstSnapshot.capture(replica);
        });

        test(
          'then the second and third field clocks advance while the unselected claim stays intact.',
          () {
            expect(
              after.rows['unique_overlapping']![loser.id]!.columns['third'],
              'renamed',
            );
            expect(after.authoredValue(firstKey), 'a');
            expect(after.authoredValue(secondKey), 'b');
            expect(after.fieldHlc(firstKey), before.fieldHlc(firstKey));
            expect(after.fieldHlc(secondKey), greaterThan(before.fieldHlc(secondKey)!));
            expect(after.fieldHlc(thirdKey), greaterThan(before.fieldHlc(thirdKey)!));
            expect(operations.committed, 1);
            expect(operations.validationFailures, 0);
            expect(operations.oracle.validate(after, space), isEmpty);
          },
        );
      },
    );
  });
}
