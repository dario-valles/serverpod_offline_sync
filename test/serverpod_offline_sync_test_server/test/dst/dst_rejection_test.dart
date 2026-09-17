import 'package:serverpod_offline_sync_test_client/serverpod_offline_sync_test_client.dart';
import 'package:test/test.dart';

import '../integration/test_tools/client_session.dart';
import 'framework/dst_authored.dart';
import 'framework/dst_random.dart';
import 'framework/dst_rejection.dart';
import 'framework/dst_snapshot.dart';
import 'framework/dst_world.dart';

void main() {
  initTestClientSession(createSessionPerTest: false);

  group('Given visible unique rows claiming claim-0 through claim-3,', () {
    late DstIds ids;
    late UuidValue space;
    late DstReplica replica;
    late DstOperations operations;
    late List<Unique> originals;
    late DstSnapshot before;

    setUp(() async {
      final random = DstRandom(43);
      ids = DstIds(random);
      space = ids.next();
      replica = await _replica(ids, [space]);
      operations = DstOperations(random, ids);
      originals = [
        for (var i = 0; i < 4; i++) Unique(id: ids.next(), name: 'claim-$i'),
      ];
      await replica.withReplicaClock(
        () => replica.session.db.transactionForUser(
          space,
          (tx) => Unique.db.insert(replica.session, originals, transaction: tx),
        ),
      );
      before = await DstSnapshot.capture(replica);
    });

    group('when a new record claims an occupied name,', () {
      late DstOperationOutcome outcome;
      late DstSnapshot after;
      setUp(() async {
        final writes = [Unique(id: ids.next(), name: 'claim-0')];
        outcome = await operations.perform(
          replica,
          space,
          table: DstTable.unique,
          action: DstAction.insert,
          body: (tx, evidence, refusal) async {
            for (final row in writes) {
              evidence.write('unique', row.toJson());
            }
            await Unique.db.insertRow(replica.session, writes.single, transaction: tx);
            return DstOperationOutcome.applied;
          },
        );
        after = await DstSnapshot.capture(replica);
      });
      test(
        'then the refusal is predicted and all domain and authored state rolls back.',
        () {
          expect(outcome, DstOperationOutcome.rejected);
          expect(operations.rejections, hasLength(1));
          expect(operations.appliedPaths, isEmpty);
          expect(after.renderSpace(space), before.renderSpace(space));
          expect(after.renderRawMetadata(), before.renderRawMetadata());
        },
      );
    });

    group('when a batch gives two new records the same unused name,', () {
      late DstOperationOutcome outcome;
      late DstSnapshot after;
      setUp(() async {
        final writes = [
          Unique(id: ids.next(), name: 'unused'),
          Unique(id: ids.next(), name: 'unused'),
        ];
        outcome = await operations.perform(
          replica,
          space,
          table: DstTable.unique,
          action: DstAction.insertBatch,
          body: (tx, evidence, refusal) async {
            for (final row in writes) {
              evidence.write('unique', row.toJson());
            }
            await Unique.db.insert(replica.session, writes, transaction: tx);
            return DstOperationOutcome.applied;
          },
        );
        after = await DstSnapshot.capture(replica);
      });
      test(
        'then the refusal is predicted and all domain and authored state rolls back.',
        () {
          expect(outcome, DstOperationOutcome.rejected);
          expect(operations.rejections, hasLength(1));
          expect(operations.appliedPaths, isEmpty);
          expect(after.renderSpace(space), before.renderSpace(space));
          expect(after.renderRawMetadata(), before.renderRawMetadata());
        },
      );
    });

    group('when a batch update gives two records the same unused name,', () {
      late DstOperationOutcome outcome;
      late DstSnapshot after;
      setUp(() async {
        final writes = [
          originals[1].copyWith(name: 'unused'),
          originals[2].copyWith(name: 'unused'),
        ];
        outcome = await operations.perform(
          replica,
          space,
          table: DstTable.unique,
          action: DstAction.updateBatch,
          body: (tx, evidence, refusal) async {
            for (final row in writes) {
              evidence.write('unique', row.toJson(), columns: {'name'});
            }
            await Unique.db.update(
              replica.session,
              writes,
              columns: (t) => [t.name],
              transaction: tx,
            );
            return DstOperationOutcome.applied;
          },
        );
        after = await DstSnapshot.capture(replica);
      });
      test(
        'then the refusal is predicted and all domain and authored state rolls back.',
        () {
          expect(outcome, DstOperationOutcome.rejected);
          expect(operations.rejections, hasLength(1));
          expect(operations.appliedPaths, isEmpty);
          expect(after.renderSpace(space), before.renderSpace(space));
          expect(after.renderRawMetadata(), before.renderRawMetadata());
        },
      );
    });

    group('when a predicate update gives two records the same unused name,', () {
      late DstOperationOutcome outcome;
      late DstSnapshot after;
      setUp(() async {
        final writes = [
          originals[1].copyWith(name: 'unused'),
          originals[2].copyWith(name: 'unused'),
        ];
        outcome = await operations.perform(
          replica,
          space,
          table: DstTable.unique,
          action: DstAction.updateWhere,
          body: (tx, evidence, refusal) async {
            for (final row in writes) {
              evidence.write('unique', row.toJson(), columns: {'name'});
            }
            await Unique.db.updateWhere(
              replica.session,
              columnValues: (t) => [t.name('unused')],
              where: (t) => t.id.inSet(<UuidValue>{originals[1].id!, originals[2].id!}),
              transaction: tx,
            );
            return DstOperationOutcome.applied;
          },
        );
        after = await DstSnapshot.capture(replica);
      });
      test(
        'then the refusal is predicted and all domain and authored state rolls back.',
        () {
          expect(outcome, DstOperationOutcome.rejected);
          expect(operations.rejections, hasLength(1));
          expect(operations.appliedPaths, isEmpty);
          expect(after.renderSpace(space), before.renderSpace(space));
          expect(after.renderRawMetadata(), before.renderRawMetadata());
        },
      );
    });
  });

  group(
    'Given two children with distinct unique references and an occupied default town,',
    () {
      late DstIds ids;
      late UuidValue space;
      late DstReplica replica;
      late DstOperations operations;
      late Town town;
      late DstSnapshot before;
      setUp(() async {
        final random = DstRandom(144);
        ids = DstIds(random);
        space = ids.next();
        replica = await _replica(ids, [space]);
        operations = DstOperations(random, ids);
        await replica.seedDefaultTown(space);
        town = Town(id: ids.next(), name: 'current');
        await replica.withReplicaClock(
          () => replica.session.db.transactionForUser(space, (tx) async {
            await Town.db.insertRow(replica.session, town, transaction: tx);
            await UniqueSetDefaultChild.db.insert(replica.session, [
              UniqueSetDefaultChild(
                id: ids.next(),
                name: 'current-child',
                parentId: town.id,
              ),
              UniqueSetDefaultChild(
                id: ids.next(),
                name: 'default-child',
                parentId: const UuidValue.raw('550e8400-e29b-41d4-a716-446655440000'),
              ),
            ], transaction: tx);
          }),
        );
        before = await DstSnapshot.capture(replica);
      });
      group(
        'when deleting the other town would assign its child the occupied default,',
        () {
          late DstOperationOutcome outcome;
          late DstSnapshot after;
          setUp(() async {
            outcome = await operations.perform(
              replica,
              space,
              table: DstTable.town,
              action: DstAction.delete,
              body: (tx, evidence, refusal) async {
                refusal.delete(DstTable.town, [town.id!]);
                evidence.visibility('town', [town.id!], deleted: true);
                await Town.db.deleteRow(replica.session, town, transaction: tx);
                return DstOperationOutcome.applied;
              },
            );
            after = await DstSnapshot.capture(replica);
          });
          test(
            'then the unique refusal is predicted and the parent, children, and authored state remain unchanged.',
            () {
              expect(outcome, DstOperationOutcome.rejected);
              expect(operations.rejections, hasLength(1));
              expect(operations.appliedPaths, isEmpty);
              expect(after.renderSpace(space), before.renderSpace(space));
              expect(after.renderRawMetadata(), before.renderRawMetadata());
            },
          );
        },
      );
    },
  );

  test(
    'Given a cascade chain with a visible no-action blocker, '
    'when the DST deletes the root, '
    'then the refusal is predicted from the rows and all authored state rolls back.',
    () async {
      final random = DstRandom(44);
      final ids = DstIds(random);
      final space = ids.next();
      final replica = await _replica(ids, [space]);
      final root = FkChainRoot(id: ids.next(), name: 'root');
      final middle = FkChainCascadeMiddle(
        id: ids.next(),
        name: 'middle',
        rootId: root.id,
      );
      final blocker = FkChainRestrictBlocker(
        id: ids.next(),
        name: 'blocker',
        cascadeMiddleId: middle.id,
      );
      await replica.withReplicaClock(
        () => replica.session.db.transactionForUser(space, (tx) async {
          await FkChainRoot.db.insertRow(replica.session, root, transaction: tx);
          await FkChainCascadeMiddle.db.insertRow(
            replica.session,
            middle,
            transaction: tx,
          );
          await FkChainRestrictBlocker.db.insertRow(
            replica.session,
            blocker,
            transaction: tx,
          );
        }),
      );
      final before = await DstSnapshot.capture(replica);
      final prediction = DstRejection(before, space)
        ..delete(DstTable.fkChainRoot, [root.id!]);
      final operations = DstOperations(random, ids);

      final outcome = await operations.apply(
        replica,
        space,
        table: DstTable.fkChainRoot,
        action: DstAction.delete,
      );
      final after = await DstSnapshot.capture(replica);

      expect(prediction.deleteReasons(definiteOnly: true), isNotEmpty);
      expect(outcome, DstOperationOutcome.rejected);
      expect(after.renderSpace(space), before.renderSpace(space));
      expect(operations.appliedPaths, isEmpty);
    },
  );

  test(
    'Given a company and both its town and default town, '
    'when the DST deletes both towns in one batch, '
    'then the unavailable batch default causes refusal without authored progress.',
    () async {
      final random = DstRandom(45);
      final ids = DstIds(random);
      final space = ids.next();
      final replica = await _replica(ids, [space]);
      await replica.seedDefaultTown(space);
      final town = Town(id: ids.next(), name: 'current');
      final company = Company(id: ids.next(), name: 'company', townId: town.id);
      await replica.withReplicaClock(
        () => replica.session.db.transactionForUser(space, (tx) async {
          await Town.db.insertRow(replica.session, town, transaction: tx);
          await Company.db.insertRow(replica.session, company, transaction: tx);
        }),
      );
      final before = await DstSnapshot.capture(replica);
      final operations = DstOperations(random, ids);

      final outcome = await operations.apply(
        replica,
        space,
        table: DstTable.town,
        action: DstAction.deleteBatch,
      );
      final after = await DstSnapshot.capture(replica);

      expect(outcome, DstOperationOutcome.rejected);
      expect(after.renderSpace(space), before.renderSpace(space));
      expect(operations.appliedPaths, isEmpty);
    },
  );

  test(
    'Given another space containing the only person and city, '
    'when the DST updates and inserts required references in the empty acting space, '
    'then space-local selection skips both operations without touching the other space.',
    () async {
      final random = DstRandom(46);
      final ids = DstIds(random);
      final space = ids.next();
      final otherSpace = ids.next();
      final replica = await _replica(ids, [space, otherSpace]);
      final operations = DstOperations(random, ids);
      await replica.withReplicaClock(
        () => replica.session.db.transactionForUser(otherSpace, (tx) async {
          await City.db.insertRow(
            replica.session,
            City(id: ids.next(), name: 'other-city'),
            transaction: tx,
          );
          await Person.db.insertRow(
            replica.session,
            Person(id: ids.next(), name: 'other-person'),
            transaction: tx,
          );
        }),
      );
      final before = await DstSnapshot.capture(replica);

      final update = await operations.apply(
        replica,
        space,
        table: DstTable.city,
        action: DstAction.update,
      );
      final insert = await operations.apply(
        replica,
        space,
        table: DstTable.requiredCascadeChild,
        action: DstAction.insert,
      );
      final after = await DstSnapshot.capture(replica);

      expect(update, DstOperationOutcome.skipped);
      expect(insert, DstOperationOutcome.skipped);
      expect(after.renderSpace(otherSpace), before.renderSpace(otherSpace));
      expect(after.renderSpace(space), before.renderSpace(space));
    },
  );

  for (final error in [
    'UNIQUE constraint failed: city.name',
    'FOREIGN KEY constraint failed',
  ]) {
    test(
      'Given a valid city insert and an injected database failure, '
      'when SQLite raises $error, '
      'then the DST surfaces the unexpected exception instead of counting a refusal.',
      () async {
        final random = DstRandom(47);
        final ids = DstIds(random);
        final space = ids.next();
        final replica = await _replica(ids, [space]);
        final operations = DstOperations(random, ids);
        // Fault injection at the actual database boundary, after normal schema
        // initialization; no mocked exception classifier or production edits.
        await replica.rawSession.db.unsafeExecute(
          "CREATE TRIGGER dst_fault BEFORE INSERT ON city BEGIN SELECT RAISE(ABORT, '$error'); END",
        );

        final result = operations.apply(
          replica,
          space,
          table: DstTable.city,
          action: DstAction.insert,
        );

        await expectLater(
          result,
          throwsA(
            isA<StateError>().having((e) => e.message, 'message', contains(error)),
          ),
        );
        expect(operations.rejections, isEmpty);
        expect(operations.appliedPaths, isEmpty);
        expect(operations.unexpected, 1);
      },
    );
  }

  test(
    'Given an accepted city insertion and a requested delete, '
    'when a successful no-op snapshot is checked against that intent, '
    'then authoring evidence rejects the missing tombstone progress.',
    () async {
      final ids = DstIds(DstRandom(48));
      final space = ids.next();
      final replica = await _replica(ids, [space]);
      final city = City(id: ids.next(), name: 'live');
      await replica.withReplicaClock(
        () => replica.session.db.transactionForUser(
          space,
          (tx) => City.db.insertRow(replica.session, city, transaction: tx),
        ),
      );
      final before = await DstSnapshot.capture(replica);
      final evidence = DstWriteEvidence(before)
        ..visibility('city', [city.id!], deleted: true);

      final violations = evidence.validate(before);

      expect(violations.map((v) => v.property), ['acceptedVisibility']);
    },
  );

  for (final result in ['unchanged', 'wrong parity', 'old clock', 'accepted']) {
    test(
      'Given an accepted city deletion and a requested restore, '
      'when a detector checks the $result restore snapshot, '
      'then authoring evidence ${result == 'accepted' ? 'accepts the new odd generation and clock' : 'rejects the missing restore progress'}.',
      () async {
        final ids = DstIds(DstRandom(96));
        final space = ids.next();
        final replica = await _replica(ids, [space]);
        final city = City(id: ids.next(), name: 'restored');
        await replica.withReplicaClock(
          () => replica.session.db.transactionForUser(space, (tx) async {
            await City.db.insertRow(replica.session, city, transaction: tx);
            await City.db.deleteRow(replica.session, city, transaction: tx);
          }),
        );
        final before = await DstSnapshot.capture(replica);
        final evidence = DstWriteEvidence(before)
          ..visibility('city', [city.id!], deleted: false);
        await replica.withReplicaClock(
          () => replica.session.db.transactionForUser(
            space,
            (tx) => City.db.insertRow(replica.session, city, transaction: tx),
          ),
        );
        final after = await DstSnapshot.capture(replica);
        final key = 'city/${city.id}';
        final restored = after.tombstones[key]!;
        final tombstone = (
          hlc: result == 'old clock' ? before.tombstones[key]!.hlc : restored.hlc,
          clFlag: result == 'wrong parity' ? restored.clFlag + 1 : restored.clFlag,
          reason: restored.reason,
        );
        // Corrupt only the detector input; persisted restore facts stay intact.
        final candidate = result == 'unchanged'
            ? before
            : DstSnapshot(
                rows: after.rows,
                projections: after.projections,
                causalLengths: after.causalLengths,
                rowHlcs: after.rowHlcs,
                fieldHlcs: after.fieldHlcs,
                tombstones: {...after.tombstones, key: tombstone},
              );

        final violations = evidence.validate(candidate);

        expect(
          violations.map((v) => v.property),
          result == 'accepted' ? isEmpty : ['acceptedVisibility'],
        );
      },
    );
  }
}

Future<DstReplica> _replica(DstIds ids, List<UuidValue> spaces) => DstReplica.create(
  name: 'replica',
  spaceUuids: spaces,
  nodeUuid: ids.next(),
  clock: DstClock().clock,
);
