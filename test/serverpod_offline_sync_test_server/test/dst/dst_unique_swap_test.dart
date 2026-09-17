import 'package:serverpod_offline_sync_server/serverpod_offline_sync_server.dart';
import 'package:serverpod_offline_sync_test_client/serverpod_offline_sync_test_client.dart';
import 'package:test/test.dart';

import '../integration/test_tools/client_session.dart';
import '../integration/test_tools/sync_topology.dart';

void main() {
  initTestClientSession();

  group('Given two visible rows contesting one unique name, ', () {
    late UuidValue space;
    late Map<UuidValue, String> before;
    late Map<UuidValue, Object?> authoredBefore;

    setUp(() async {
      space = const Uuid().v7obj();
      final first = Unique(id: const Uuid().v7obj(), name: 'contested');
      final second = Unique(id: const Uuid().v7obj(), name: 'contested');
      await session.db.transactionForUser(
        space,
        (tx) => Unique.db.insertRow(session, first, transaction: tx),
      );
      await mergeIndependentInsert(session, second, space: space, tables: [Unique.t]);
      before = await _names();
      authoredBefore = await _authoredNames();
    });

    group(
      'when a batch exchanges the materialised names of the winner and a released loser, ',
      () {
        Object? failure;

        setUp(() async {
          final winner = before.entries
              .singleWhere((row) => row.value == 'contested')
              .key;
          final loser = before.entries
              .firstWhere((row) => row.value != 'contested')
              .key;
          failure = null;
          try {
            await session.db.transactionForUser(
              space,
              (tx) => Unique.db.update(
                session,
                [
                  Unique(id: winner, name: before[loser]!),
                  Unique(id: loser, name: before[winner]!),
                ],
                columns: (t) => [t.name],
                transaction: tx,
              ),
            );
          } on Object catch (error) {
            failure = error;
          }
        });

        test(
          'then the reserved name is rejected and all original claims remain intact.',
          () async {
            expect(before.values.toSet(), hasLength(2));
            expect(failure, isA<OfflineSyncReservedValueException>());
            expect(await _names(), before);
            expect(await _authoredNames(), authoredBefore);
          },
        );
      },
    );
  });

  group('Given three visible rows contesting one unique name, ', () {
    late UuidValue space;
    late Map<UuidValue, String> before;
    late Map<UuidValue, Object?> authoredBefore;

    setUp(() async {
      space = const Uuid().v7obj();
      final first = Unique(id: const Uuid().v7obj(), name: 'contested');
      final second = Unique(id: const Uuid().v7obj(), name: 'contested');
      await session.db.transactionForUser(
        space,
        (tx) => Unique.db.insertRow(session, first, transaction: tx),
      );
      await mergeIndependentInsert(session, second, space: space, tables: [Unique.t]);
      final third = Unique(id: const Uuid().v7obj(), name: 'contested');
      await mergeIndependentInsert(session, third, space: space, tables: [Unique.t]);
      before = await _names();
      authoredBefore = await _authoredNames();
    });

    group(
      'when a batch exchanges the materialised names of the winner and a released loser, ',
      () {
        Object? failure;

        setUp(() async {
          final winner = before.entries
              .singleWhere((row) => row.value == 'contested')
              .key;
          final loser = before.entries
              .firstWhere((row) => row.value != 'contested')
              .key;
          failure = null;
          try {
            await session.db.transactionForUser(
              space,
              (tx) => Unique.db.update(
                session,
                [
                  Unique(id: winner, name: before[loser]!),
                  Unique(id: loser, name: before[winner]!),
                ],
                columns: (t) => [t.name],
                transaction: tx,
              ),
            );
          } on Object catch (error) {
            failure = error;
          }
        });

        test(
          'then the reserved name is rejected and all original claims remain intact.',
          () async {
            expect(before.values.toSet(), hasLength(3));
            expect(failure, isA<OfflineSyncReservedValueException>());
            expect(await _names(), before);
            expect(await _authoredNames(), authoredBefore);
          },
        );
      },
    );

    group('when the two released losers exchange their materialised names, ', () {
      late List<UuidValue> losers;
      Object? failure;

      setUp(() async {
        losers = before.entries
            .where((row) => row.value != 'contested')
            .map((row) => row.key)
            .toList();
        failure = null;
        try {
          await session.db.transactionForUser(
            space,
            (tx) => Unique.db.update(
              session,
              [
                Unique(id: losers[0], name: before[losers[1]]!),
                Unique(id: losers[1], name: before[losers[0]]!),
              ],
              columns: (t) => [t.name],
              transaction: tx,
            ),
          );
        } on Object catch (error) {
          failure = error;
        }
      });

      test(
        'then the reserved names are rejected and all original claims remain intact.',
        () async {
          expect(losers, hasLength(2));
          expect(failure, isA<OfflineSyncReservedValueException>());
          expect(await _names(), before);
          expect(await _authoredNames(), authoredBefore);
        },
      );
    });
  });
}

Future<Map<UuidValue, String>> _names() async => {
  for (final row in await Unique.db.find(session)) row.id!: row.name,
};

/// Public ORM evidence only, independent of the DST snapshot or authoring
/// oracle: the sparse record retains a claim while the domain is projected.
Future<Map<UuidValue, Object?>> _authoredNames() async {
  final attempts = await CrdtDataAttemptedValue.db.find(
    testSession,
    include: CrdtDataAttemptedValue.include(
      field: CrdtDataField.include(
        row: CrdtDataRow.include(tbl: CrdtSchemaTable.include()),
        column: CrdtSchemaColumn.include(),
      ),
    ),
  );
  return {
    ...await _names(),
    for (final attempt in attempts)
      if (attempt.field!.row!.tbl!.name == 'unique' &&
          attempt.field!.column!.name == 'name')
        attempt.field!.row!.uuidRowId: attempt.value,
  };
}
