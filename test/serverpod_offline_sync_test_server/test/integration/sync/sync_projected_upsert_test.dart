import 'package:serverpod_offline_sync_test_client/serverpod_offline_sync_test_client.dart';
import 'package:test/test.dart';

import '../test_tools/client_session.dart';
import '../test_tools/sync_topology.dart';

void main() {
  initTestClientSession(createSessionPerTest: false);

  group('Given a visible record whose unique value 0 is projected to null, ', () {
    late SyncNode source;
    late UniqueNullable winner;
    late UniqueNullable loser;

    setUp(() async {
      source = await syncNode(await createAdditionalTestSession(), [UniqueNullable.t]);
      winner = UniqueNullable(id: const Uuid().v7obj(), value: 0);
      loser = UniqueNullable(id: const Uuid().v7obj(), value: 0);
      await source.offlineSync.db.transactionForUser(testCrdtUserId, (tx) async {
        await UniqueNullable.db.insertRow(source.offlineSync, winner, transaction: tx);
      });
      await mergeIndependentInsert(
        source.offlineSync,
        loser,
        space: testCrdtUserId,
        tables: [UniqueNullable.t],
      );
    });

    group('when a full-row upsert writes 1 and an empty peer bootstraps, ', () {
      late SyncNode target;

      setUp(() async {
        target = await syncNode(await createAdditionalTestSession(), [
          UniqueNullable.t,
        ]);
        await source.offlineSync.db.transactionForUser(
          testCrdtUserId,
          (tx) => UniqueNullable.db.upsertRow(
            source.offlineSync,
            loser.copyWith(value: 1),
            conflictColumns: (t) => [t.id],
            transaction: tx,
          ),
        );
        await pushChanges(source, target);
      });

      test('then both replicas retain the new value.', () async {
        expect(
          (await UniqueNullable.db.findById(source.offlineSync, loser.id!))!.value,
          1,
        );
        expect(
          (await UniqueNullable.db.findById(target.offlineSync, loser.id!))!.value,
          1,
        );
      });
    });

    group('when a value-only upsert writes 1 and an empty peer bootstraps, ', () {
      late SyncNode target;

      setUp(() async {
        target = await syncNode(await createAdditionalTestSession(), [
          UniqueNullable.t,
        ]);
        await source.offlineSync.db.transactionForUser(
          testCrdtUserId,
          (tx) => UniqueNullable.db.upsertRow(
            source.offlineSync,
            loser.copyWith(value: 1),
            conflictColumns: (t) => [t.id],
            updateColumns: (t) => [t.value],
            transaction: tx,
          ),
        );
        await pushChanges(source, target);
      });

      test('then both replicas retain the new value.', () async {
        expect(
          (await UniqueNullable.db.findById(source.offlineSync, loser.id!))!.value,
          1,
        );
        expect(
          (await UniqueNullable.db.findById(target.offlineSync, loser.id!))!.value,
          1,
        );
      });
    });

    group(
      'when an upsert excludes it with updateWhere and the winner is later deleted, ',
      () {
        setUp(() async {
          await source.offlineSync.db.transactionForUser(testCrdtUserId, (tx) async {
            await UniqueNullable.db.upsertRow(
              source.offlineSync,
              loser.copyWith(value: 1),
              conflictColumns: (t) => [t.id],
              updateColumns: (t) => [t.value],
              updateWhere: (t) => t.value.equals(999),
              transaction: tx,
            );
            await UniqueNullable.db.deleteRow(
              source.offlineSync,
              winner,
              transaction: tx,
            );
          });
        });

        test('then the record reclaims its original value.', () async {
          expect(
            (await UniqueNullable.db.findById(source.offlineSync, loser.id!))!.value,
            0,
          );
        });
      },
    );

    group(
      'when a value-only upsert explicitly clears its claim and the winner is deleted, ',
      () {
        setUp(() async {
          await source.offlineSync.db.transactionForUser(testCrdtUserId, (tx) async {
            await UniqueNullable.db.upsertRow(
              source.offlineSync,
              loser.copyWith(value: null),
              conflictColumns: (t) => [t.id],
              updateColumns: (t) => [t.value],
              transaction: tx,
            );
            await UniqueNullable.db.deleteRow(
              source.offlineSync,
              winner,
              transaction: tx,
            );
          });
        });

        test('then the record keeps the authored null.', () async {
          expect(
            (await UniqueNullable.db.findById(source.offlineSync, loser.id!))!.value,
            isNull,
          );
        });
      },
    );
  });

  group(
    'Given a record projected by one unique index and identifiable through another, ',
    () {
      late SyncNode node;
      late UniqueOverlapping loser;

      setUpAll(() async {
        node = await syncNode(await createAdditionalTestSession(), [
          UniqueOverlapping.t,
        ]);
        final winner = UniqueOverlapping(
          id: const Uuid().v7obj(),
          first: 'a',
          second: 'b',
          third: 'c',
        );
        loser = UniqueOverlapping(
          id: const Uuid().v7obj(),
          first: 'a',
          second: 'b',
          third: 'z',
        );
        await node.offlineSync.db.transactionForUser(testCrdtUserId, (tx) async {
          await UniqueOverlapping.db.insertRow(
            node.offlineSync,
            winner,
            transaction: tx,
          );
        });
        await mergeIndependentInsert(
          node.offlineSync,
          loser,
          space: testCrdtUserId,
          tables: [UniqueOverlapping.t],
        );
      });

      group(
        'when an upsert matches the second index and writes a free first value, ',
        () {
          late UniqueOverlapping? saved;

          setUpAll(() async {
            saved = await node.offlineSync.db.transactionForUser(
              testCrdtUserId,
              (tx) => UniqueOverlapping.db.upsertRow(
                node.offlineSync,
                UniqueOverlapping(first: 'free', second: 'b', third: 'z'),
                conflictColumns: (t) => [t.spaceId, t.second, t.third],
                updateColumns: (t) => [t.first],
                transaction: tx,
              ),
            );
          });

          test('then the existing record retains the new value.', () async {
            expect(saved!.id, loser.id);
            expect(
              (await UniqueOverlapping.db.findById(node.offlineSync, loser.id!))!.first,
              'free',
            );
          });
        },
      );
    },
  );
}
