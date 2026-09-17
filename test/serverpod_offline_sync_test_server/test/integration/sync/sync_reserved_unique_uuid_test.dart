import 'dart:typed_data';

import 'package:serverpod_database/serverpod_database.dart'
    show DatabaseUniqueViolationException, Transaction;
import 'package:serverpod_offline_sync_server/serverpod_offline_sync_server.dart';
import 'package:serverpod_offline_sync_test_client/serverpod_offline_sync_test_client.dart';
import 'package:test/test.dart';

import '../../dst/framework/dst_random.dart';
import '../../dst/framework/dst_snapshot.dart';
import '../../dst/framework/dst_world.dart';
import '../test_tools/client_session.dart';
import '../test_tools/sync_topology.dart';

void main() {
  initTestClientSession(createSessionPerTest: false);

  const reserved = UuidValue.raw('1384ce72-7ccf-8b5f-afc4-4fb11ac066d9');
  const ordinary = UuidValue.raw('660e8400-e29b-41d4-a716-446655440000');
  const other = UuidValue.raw('660e8400-e29b-41d4-a716-446655440001');

  for (final operation in [
    'insert',
    'batch insert',
    'full-row update',
    'value-only update',
    'batch update',
    'new-row upsert',
    'existing-row upsert',
    'batch upsert',
    'predicate update',
    'restore',
  ]) {
    test(
      'Given a unique UUID column and a reserved version-8 input, '
      'when $operation authors that value, '
      'then the entire transaction is rejected without domain or sync changes.',
      () async {
        final node = await syncNode(await createAdditionalTestSession(), [
          UniqueUuid.t,
        ]);
        final row = UniqueUuid(id: const Uuid().v7obj(), value: ordinary);
        await node.offlineSync.db.transactionForUser(testCrdtUserId, (tx) async {
          await UniqueUuid.db.insertRow(node.offlineSync, row, transaction: tx);
          if (operation == 'restore') {
            await UniqueUuid.db.deleteRow(node.offlineSync, row, transaction: tx);
          }
        });
        final before = await _state(node);
        final invalid = row.copyWith(value: reserved);
        final fresh = invalid.copyWith(id: const Uuid().v7obj());
        final earlier = UniqueUuid(id: const Uuid().v7obj(), value: other);
        final valid = UniqueUuid(id: const Uuid().v7obj(), value: const Uuid().v7obj());

        await expectLater(
          node.offlineSync.db.transactionForUser(testCrdtUserId, (tx) async {
            // An earlier valid write must roll back along with the rejected input.
            await UniqueUuid.db.insertRow(
              node.offlineSync,
              earlier,
              transaction: tx,
            );
            switch (operation) {
              case 'insert':
                await UniqueUuid.db.insertRow(node.offlineSync, fresh, transaction: tx);
              case 'batch insert':
                await UniqueUuid.db.insert(node.offlineSync, [
                  valid,
                  fresh,
                ], transaction: tx);
              case 'full-row update':
                await UniqueUuid.db.updateRow(
                  node.offlineSync,
                  invalid,
                  transaction: tx,
                );
              case 'value-only update':
                await UniqueUuid.db.updateRow(
                  node.offlineSync,
                  invalid,
                  columns: (t) => [t.value],
                  transaction: tx,
                );
              case 'batch update':
                await UniqueUuid.db.update(node.offlineSync, [
                  earlier.copyWith(value: valid.value),
                  invalid,
                ], transaction: tx);
              case 'new-row upsert':
                await UniqueUuid.db.upsertRow(
                  node.offlineSync,
                  fresh,
                  conflictColumns: (t) => [t.id],
                  transaction: tx,
                );
              case 'existing-row upsert':
              case 'restore':
                await UniqueUuid.db.upsertRow(
                  node.offlineSync,
                  invalid,
                  conflictColumns: (t) => [t.id],
                  transaction: tx,
                );
              case 'batch upsert':
                await UniqueUuid.db.upsert(
                  node.offlineSync,
                  [valid, invalid],
                  conflictColumns: (t) => [t.id],
                  transaction: tx,
                );
              case 'predicate update':
                await UniqueUuid.db.updateWhere(
                  node.offlineSync,
                  columnValues: (t) => [t.value(reserved)],
                  where: (t) => t.id.equals(row.id),
                  transaction: tx,
                );
            }
          }),
          throwsA(
            isA<OfflineSyncReservedValueException>()
                .having((e) => e.tableName, 'table', 'unique_uuid')
                .having((e) => e.columnName, 'column', 'value')
                .having((e) => e.value, 'value', reserved.toString()),
          ),
        );
        expect(await _state(node), before);
      },
    );
  }

  for (final operation in ['update', 'upsert', 'insert restore', 'upsert restore']) {
    test(
      'Given a UUID claim displayed as a generated alternative, '
      'when its own unchanged model is saved with $operation and exported, '
      'then its original claim survives and a fresh device reconstructs the same state.',
      () async {
        final node = await syncNode(await createAdditionalTestSession(), [
          UniqueUuid.t,
        ]);
        final target = await syncNode(await createAdditionalTestSession(), [
          UniqueUuid.t,
        ]);
        final winner = UniqueUuid(id: const Uuid().v7obj(), value: ordinary);
        final loser = UniqueUuid(id: const Uuid().v7obj(), value: ordinary);
        await node.offlineSync.db.transactionForUser(
          testCrdtUserId,
          (tx) => UniqueUuid.db.insertRow(node.offlineSync, winner, transaction: tx),
        );
        await mergeIndependentInsert(
          node.offlineSync,
          loser,
          space: testCrdtUserId,
          tables: [UniqueUuid.t],
        );
        if (operation.endsWith('restore')) {
          await node.offlineSync.db.transactionForUser(
            testCrdtUserId,
            (tx) => UniqueUuid.db.deleteRow(node.offlineSync, loser, transaction: tx),
          );
        }
        final displayed = (await UniqueUuid.db.find(
          node.offlineSync,
          where: (t) => t.id.equals(loser.id) & t.includeHiddenRows,
        )).single;
        expect(displayed.value.version, 8);
        await node.offlineSync.db.transactionForUser(testCrdtUserId, (tx) async {
          if (operation == 'update') {
            await UniqueUuid.db.updateRow(node.offlineSync, displayed, transaction: tx);
          } else if (operation == 'insert restore') {
            await UniqueUuid.db.insertRow(node.offlineSync, displayed, transaction: tx);
          } else {
            await UniqueUuid.db.upsertRow(
              node.offlineSync,
              displayed,
              conflictColumns: (t) => [t.id],
              transaction: tx,
            );
          }
        });
        final changes = await _export(node);
        expect(
          changes.whereType<CrdtMergeInsert>().map((c) => (c.data as UniqueUuid).value),
          everyElement(ordinary),
        );
        expect(
          changes.whereType<CrdtMergeUpdate>().map((c) => c.value),
          everyElement(ordinary),
        );
        await pushChanges(node, target);
        expect(await _domain(target), await _domain(node));
        expect(await _facts(target), await _facts(node));
      },
    );
  }

  for (final operation in ['insert', 'explicit update', 'explicit upsert']) {
    test(
      'Given a generated conflict UUID whose winning competitor was deleted, '
      'when $operation explicitly authors the now-unoccupied alternative, '
      'then the reserved value is rejected regardless of the current domain data.',
      () async {
        final node = await syncNode(await createAdditionalTestSession(), [
          UniqueUuid.t,
        ]);
        final winner = UniqueUuid(id: const Uuid().v7obj(), value: ordinary);
        final loser = UniqueUuid(id: const Uuid().v7obj(), value: ordinary);
        await node.offlineSync.db.transactionForUser(
          testCrdtUserId,
          (tx) => UniqueUuid.db.insertRow(node.offlineSync, winner, transaction: tx),
        );
        await mergeIndependentInsert(
          node.offlineSync,
          loser,
          space: testCrdtUserId,
          tables: [UniqueUuid.t],
        );
        final displayed = (await UniqueUuid.db.findById(node.offlineSync, loser.id!))!;
        expect(displayed.value.version, 8);
        await node.offlineSync.db.transactionForUser(
          testCrdtUserId,
          (tx) => UniqueUuid.db.deleteRow(node.offlineSync, winner, transaction: tx),
        );
        expect((await UniqueUuid.db.find(node.offlineSync)).single.value, ordinary);
        final before = await _state(node);
        await expectLater(
          node.offlineSync.db.transactionForUser(testCrdtUserId, (tx) async {
            if (operation == 'insert') {
              await UniqueUuid.db.insertRow(
                node.offlineSync,
                displayed.copyWith(id: const Uuid().v7obj()),
                transaction: tx,
              );
            } else if (operation == 'explicit update') {
              await UniqueUuid.db.updateRow(
                node.offlineSync,
                displayed,
                columns: (t) => [t.value],
                transaction: tx,
              );
            } else {
              await UniqueUuid.db.upsertRow(
                node.offlineSync,
                displayed,
                conflictColumns: (t) => [t.id],
                updateColumns: (t) => [t.value],
                transaction: tx,
              );
            }
          }),
          throwsA(
            isA<OfflineSyncReservedValueException>().having(
              (e) => e.value,
              'generated alternative',
              displayed.value.toString(),
            ),
          ),
        );
        expect(await _state(node), before);
      },
    );
  }

  for (final changeType in ['insert', 'typed update', 'string update']) {
    test(
      'Given an incoming batch containing a reserved UUID $changeType, '
      'when it is delivered repeatedly and in reversed order, '
      'then every delivery is rejected without changing data or sync progress.',
      () async {
        final source = await syncNode(await createAdditionalTestSession(), [
          UniqueUuid.t,
        ]);
        final target = await syncNode(await createAdditionalTestSession(), [
          UniqueUuid.t,
        ]);
        final row = UniqueUuid(id: const Uuid().v7obj(), value: ordinary);
        await source.offlineSync.db.transactionForUser(
          testCrdtUserId,
          (tx) => UniqueUuid.db.insertRow(source.offlineSync, row, transaction: tx),
        );
        if (changeType != 'insert') {
          await pushChanges(source, target);
          await source.offlineSync.db.transactionForUser(
            testCrdtUserId,
            (tx) => UniqueUuid.db.updateRow(
              source.offlineSync,
              row.copyWith(value: other),
              columns: (t) => [t.value],
              transaction: tx,
            ),
          );
        }
        await source.offlineSync.db.transactionForUser(
          testCrdtUserId,
          (tx) => UniqueUuid.db.insertRow(
            source.offlineSync,
            UniqueUuid(id: const Uuid().v7obj(), value: const Uuid().v7obj()),
            transaction: tx,
          ),
        );
        final invalid = (await _export(source)).map((change) {
          if (changeType == 'insert' &&
              change is CrdtMergeInsert &&
              change.uuidRowId == row.id) {
            return change.copyWith(data: row.copyWith(value: reserved));
          }
          if (change is CrdtMergeUpdate) {
            return change.copyWith(
              value: changeType == 'string update' ? reserved.toString() : reserved,
            );
          }
          return change;
        }).toList();
        await target.offlineSync.db.transactionForUser(testCrdtUserId, (_) async {});
        final before = await _state(target);
        for (final batch in [invalid, invalid.reversed.toList(), invalid]) {
          await expectLater(
            target.offlineSync.db.mergeChanges(batch, spaceId: testCrdtUserId),
            throwsA(isA<OfflineSyncReservedValueException>()),
          );
          expect(await _state(target), before);
        }
      },
    );
  }

  test(
    'Given ordinary version-4, version-5, and version-7 unique UUIDs, '
    'when they are inserted and synchronized, '
    'then all authored UUIDs remain unchanged.',
    () async {
      final source = await syncNode(await createAdditionalTestSession(), [
        UniqueUuid.t,
      ]);
      final target = await syncNode(await createAdditionalTestSession(), [
        UniqueUuid.t,
      ]);
      final values = [
        ordinary,
        const UuidValue.raw('1384ce72-7ccf-5b5f-afc4-4fb11ac066d9'),
        const Uuid().v7obj(),
      ];
      await source.offlineSync.db.transactionForUser(
        testCrdtUserId,
        (tx) => UniqueUuid.db.insert(source.offlineSync, [
          for (final value in values)
            UniqueUuid(id: const Uuid().v7obj(), value: value),
        ], transaction: tx),
      );
      await pushChanges(source, target);
      expect(
        (await UniqueUuid.db.find(target.offlineSync)).map((r) => r.value),
        unorderedEquals(values),
      );
    },
  );

  test(
    'Given an untracked unique UUID table, '
    'when a version-8 value is inserted through the sync session, '
    'then the database accepts the first claim and enforces ordinary uniqueness.',
    () async {
      final node = await syncNode(await createAdditionalTestSession(), [City.t]);
      await node.offlineSync.db.transactionForUser(testCrdtUserId, (_) async {});
      final space = (await OfflineSyncSpace.db.find(node.raw)).single;
      final row = UniqueUuid(
        id: const Uuid().v7obj(),
        spaceId: space.id,
        value: reserved,
      );
      await node.offlineSync.db.transactionForUser(
        testCrdtUserId,
        (tx) => UniqueUuid.db.insertRow(node.offlineSync, row, transaction: tx),
      );
      await expectLater(
        node.offlineSync.db.transactionForUser(
          testCrdtUserId,
          (tx) => UniqueUuid.db.insertRow(
            node.offlineSync,
            row.copyWith(id: const Uuid().v7obj()),
            transaction: tx,
          ),
        ),
        throwsA(isA<DatabaseUniqueViolationException>()),
      );
      expect((await UniqueUuid.db.find(node.offlineSync)).single.value, reserved);
    },
  );

  test(
    'Given version-8 primary keys, foreign keys, and a non-unique UUID column, '
    'when they are inserted and synchronized, '
    'then these UUIDs remain valid ordinary data.',
    () async {
      final tables = [Person.t, Town.t, Types.t, UniqueCascadeReference.t];
      final source = await syncNode(await createAdditionalTestSession(), tables);
      final target = await syncNode(await createAdditionalTestSession(), tables);
      final person = Person(id: reserved, name: 'mayor');
      final town = Town(id: const Uuid().v7obj(), name: 'town', mayorId: reserved);
      final types = Types(
        id: const Uuid().v7obj(),
        aBool: true,
        aDateTime: DateTime.utc(2026),
        aText: reserved.toString(),
        anInt: 1,
        anInt64: BigInt.one,
        aReal: 1,
        aBlob: ByteData(0),
        optionalUuid: reserved,
      );
      await source.offlineSync.db.transactionForUser(testCrdtUserId, (tx) async {
        await Person.db.insertRow(source.offlineSync, person, transaction: tx);
        await Town.db.insertRow(source.offlineSync, town, transaction: tx);
        await Types.db.insertRow(source.offlineSync, types, transaction: tx);
        await UniqueCascadeReference.db.insertRow(
          source.offlineSync,
          UniqueCascadeReference(
            id: const Uuid().v7obj(),
            name: 'unique reference',
            parentId: reserved,
          ),
          transaction: tx,
        );
      });
      await pushChanges(source, target);
      expect((await Person.db.find(target.offlineSync)).single.id, reserved);
      expect((await Town.db.find(target.offlineSync)).single.mayorId, reserved);
      expect((await Types.db.find(target.offlineSync)).single.optionalUuid, reserved);
      expect(
        (await UniqueCascadeReference.db.find(target.offlineSync)).single.parentId,
        reserved,
      );
    },
  );

  test(
    'Given a unique UUID column and a generated version-8 input, '
    'when the DST tries to author it, '
    'then it predicts the precise refusal and verifies complete rollback.',
    () async {
      final random = DstRandom(62);
      final ids = DstIds(random);
      final space = ids.next();
      final replica = await DstReplica.create(
        name: 'reserved-uuid',
        spaceUuids: [space],
        nodeUuid: ids.next(),
        clock: DstClock().clock,
      );
      final before = await DstSnapshot.capture(replica);
      final operations = DstOperations(random, ids);
      final row = UniqueUuid(id: ids.next(), value: reserved);
      final result = await operations.perform(
        replica,
        space,
        table: DstTable.uniqueUuid,
        action: DstAction.insert,
        body: (Transaction tx, evidence, refusal) async {
          evidence.write('unique_uuid', row.toJson());
          await UniqueUuid.db.insertRow(replica.session, row, transaction: tx);
          return DstOperationOutcome.applied;
        },
      );
      expect(result, DstOperationOutcome.rejected);
      expect(operations.rejections, [
        'Reserved generated unique value for unique_uuid.value: $reserved',
      ]);
      expect(
        (await DstSnapshot.capture(replica)).renderRawMetadata(),
        before.renderRawMetadata(),
      );
    },
  );
}

Future<List<CrdtMergeChange>> _export(SyncNode node) => node.sync
    .collectPendingChanges(
      node.raw,
      checkpointsBySpaceUuid: {testCrdtUserId: const []},
    )
    .toList();

Future<List<Object?>> _facts(SyncNode node) async =>
    (await _export(node)).map((c) => c.toJson()).toList();

Future<Map<String, String>> _domain(SyncNode node) async => {
  for (final row in await UniqueUuid.db.find(
    node.offlineSync,
    where: (t) => t.includeHiddenRows,
  ))
    row.id.toString(): row.value.toString(),
};

Future<Object> _state(SyncNode node) async => [
  await _domain(node),
  await _facts(node),
  for (final row in await OfflineSyncSpace.db.find(node.raw)) row.toJson(),
];
