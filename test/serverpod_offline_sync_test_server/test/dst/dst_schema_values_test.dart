import 'package:serverpod_offline_sync_test_client/serverpod_offline_sync_test_client.dart';
import 'package:serverpod_offline_sync_test_shared/serverpod_offline_sync_test_shared.dart';
import 'package:test/test.dart';

import '../integration/test_tools/client_session.dart';
import 'framework/dst_random.dart';
import 'framework/dst_world.dart';

void main() {
  initTestClientSession(createSessionPerTest: false);

  test(
    'Given shared-package parent and child rows authored by the DST, '
    'when its predicate adapter changes the child flavor and an empty peer bootstraps, '
    'then the string-backed enum and parent relation survive synchronization.',
    () async {
      final random = DstRandom(91);
      final ids = DstIds(random);
      final space = ids.next();
      final source = await _replica(ids, space);
      final target = await _replica(ids, space);
      final operations = DstOperations(random, ids);
      for (final table in [DstTable.sharedParent, DstTable.sharedChild]) {
        expect(
          await operations.apply(source, space, table: table, action: DstAction.insert),
          DstOperationOutcome.applied,
        );
      }
      final parent = (await SharedParent.db.find(source.session)).single;
      final child = (await SharedChild.db.find(source.session)).single;
      await source.withReplicaClock(
        () => source.session.db.transactionForUser(
          space,
          (tx) => DstTable.sharedChild.model.updateWhere(
            source.session,
            {child.id!},
            {'flavor': 'salted', 'parentId': parent.id!.toJson()},
            tx,
          ),
        ),
      );
      await target.merge(await source.collect(space), space);

      final received = (await SharedChild.db.find(target.session)).single;
      expect(received.flavor, SharedFlavor.salted);
      expect(received.parentId, parent.id);
      expect((await SharedParent.db.find(target.session)).single.id, parent.id);
    },
  );

  test(
    'Given a typed row authored by the DST with structured JSON fields, '
    'when its predicate adapter writes documents and a number list and a peer bootstraps, '
    'then JSON and JSONB retain the supplied structured values.',
    () async {
      final random = DstRandom(92);
      final ids = DstIds(random);
      final space = ids.next();
      final source = await _replica(ids, space);
      final target = await _replica(ids, space);
      final operations = DstOperations(random, ids);
      expect(
        await operations.apply(
          source,
          space,
          table: DstTable.types,
          action: DstAction.insert,
        ),
        DstOperationOutcome.applied,
      );
      final row = (await Types.db.find(source.session)).single;
      final document = SyncDocument(title: 'saved', enabled: false, numbers: [3, -7]);
      await source.withReplicaClock(
        () => source.session.db.transactionForUser(
          space,
          (tx) => DstTable.types.model.updateWhere(
            source.session,
            {row.id!},
            {
              'jsonDocument': document.toJson(),
              'jsonbDocument': document.toJson(),
              'jsonbNumbers': [13, -5],
            },
            tx,
          ),
        ),
      );
      await target.merge(await source.collect(space), space);

      final received = (await Types.db.find(target.session)).single;
      expect(received.jsonDocument!.toJson(), document.toJson());
      expect(received.jsonbDocument!.toJson(), document.toJson());
      expect(received.jsonbNumbers, [13, -5]);
    },
  );
}

Future<DstReplica> _replica(DstIds ids, UuidValue space) => DstReplica.create(
  name: 'schema-values',
  spaceUuids: [space],
  nodeUuid: ids.next(),
  clock: DstClock().clock,
);
