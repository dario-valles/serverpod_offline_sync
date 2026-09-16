import 'package:serverpod_offline_sync_server/serverpod_offline_sync_server.dart';
import 'package:serverpod_offline_sync_test_client/serverpod_offline_sync_test_client.dart';
import 'package:test/test.dart';

import '../integration/test_tools/client_session.dart';

void main() {
  initTestClientSession();

  for (final count in [2, 3]) {
    test(
      'Given $count visible rows contesting one unique name, '
      'when a batch exchanges the winner and a released loser\'s materialised names, '
      'then the batch commits and preserves every submitted authored claim.',
      () async {
        final space = const Uuid().v7obj();
        await _contest(space, count: count, claim: 'contested');
        final before = await _names();
        expect(before.values.toSet(), hasLength(count));
        final winner = before.entries
            .singleWhere((row) => row.value == 'contested')
            .key;
        final loser = before.entries.firstWhere((row) => row.value != 'contested').key;

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

        // The untouched third claimant can win the name by its older claim
        // clock. Submission must survive regardless of that valid projection.
        expect((await _names()).keys.toSet(), before.keys.toSet());
        expect(await _authoredNames(), {
          for (final id in before.keys) id: 'contested',
          winner: before[loser],
          loser: before[winner],
        });
      },
    );
  }

  test(
    'Given three visible rows contesting one unique name, '
    'when the two released losers exchange their materialised names, '
    'then the batch commits and preserves every submitted authored claim.',
    () async {
      final space = const Uuid().v7obj();
      await _contest(space, count: 3, claim: 'contested');
      final before = await _names();
      final losers = before.entries
          .where((row) => row.value != 'contested')
          .map((row) => row.key)
          .toList();
      expect(losers, hasLength(2));

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

      expect((await _names()).keys.toSet(), before.keys.toSet());
      expect(await _authoredNames(), {
        for (final id in before.keys) id: 'contested',
        losers[0]: before[losers[1]],
        losers[1]: before[losers[0]],
      });
    },
  );
}

Future<void> _contest(
  UuidValue space, {
  required int count,
  required String claim,
}) async {
  final rows = [
    for (var index = 0; index < count; index++)
      Unique(id: const Uuid().v7obj(), name: 'initial-$index'),
  ];
  await session.db.transactionForUser(
    space,
    (tx) => Unique.db.insert(session, rows, transaction: tx),
  );
  await session.db.transactionForUser(
    space,
    (tx) => Unique.db.update(
      session,
      [for (final row in rows) row.copyWith(name: claim)],
      columns: (t) => [t.name],
      transaction: tx,
    ),
  );
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
