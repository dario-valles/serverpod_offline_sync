import 'package:serverpod_offline_sync_test_client/serverpod_offline_sync_test_client.dart';
import 'package:test/test.dart';

import '../test_tools/client_session.dart';
import '../test_tools/sync_topology.dart';

void main() {
  initTestClientSession(createSessionPerTest: false);

  group('Given competing unique names containing UUID-shaped text, ', () {
    late SyncNode source;
    late SyncNode target;
    late Unique winner;
    late Unique loser;
    const value = '550E8400-E29B-41D4-A716-446655440111';

    setUpAll(() async {
      source = await syncNode(await createAdditionalTestSession(), [Unique.t]);
      target = await syncNode(await createAdditionalTestSession(), [Unique.t]);
      winner = Unique(id: const Uuid().v7obj(), name: value);
      loser = Unique(id: const Uuid().v7obj(), name: value);
      await source.offlineSync.db.transactionForUser(testCrdtUserId, (tx) async {
        await Unique.db.insertRow(source.offlineSync, winner, transaction: tx);
      });
      await mergeIndependentInsert(
        source.offlineSync,
        loser,
        space: testCrdtUserId,
        tables: [Unique.t],
      );
    });

    group('when an empty peer bootstraps and the original winner is deleted, ', () {
      setUpAll(() async {
        await pushChanges(source, target);
        await target.offlineSync.db.transactionForUser(
          testCrdtUserId,
          (tx) => Unique.db.deleteRow(target.offlineSync, winner, transaction: tx),
        );
      });

      test('then the remaining record reclaims the exact original text.', () async {
        expect(
          (await Unique.db.findById(target.offlineSync, loser.id!))!.name,
          value,
        );
      });
    });
  });

  group('Given competing values in a unique UUID column, ', () {
    late SyncNode source;
    late SyncNode target;
    late UniqueUuid winner;
    late UniqueUuid loser;
    final value = UuidValue.fromString('550e8400-e29b-41d4-a716-446655440111');

    setUpAll(() async {
      source = await syncNode(await createAdditionalTestSession(), [UniqueUuid.t]);
      target = await syncNode(await createAdditionalTestSession(), [UniqueUuid.t]);
      winner = UniqueUuid(id: const Uuid().v7obj(), value: value);
      loser = UniqueUuid(id: const Uuid().v7obj(), value: value);
      await source.offlineSync.db.transactionForUser(testCrdtUserId, (tx) async {
        await UniqueUuid.db.insertRow(source.offlineSync, winner, transaction: tx);
      });
      await mergeIndependentInsert(
        source.offlineSync,
        loser,
        space: testCrdtUserId,
        tables: [UniqueUuid.t],
      );
    });

    group('when an empty peer bootstraps and the original winner is deleted, ', () {
      setUpAll(() async {
        await pushChanges(source, target);
        await target.offlineSync.db.transactionForUser(
          testCrdtUserId,
          (tx) => UniqueUuid.db.deleteRow(target.offlineSync, winner, transaction: tx),
        );
      });

      test('then the remaining record reclaims the original typed UUID.', () async {
        expect(
          (await UniqueUuid.db.findById(target.offlineSync, loser.id!))!.value,
          value,
        );
      });
    });
  });
}
