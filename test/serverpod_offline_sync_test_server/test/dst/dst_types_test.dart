import 'dart:typed_data';

import 'package:serverpod_offline_sync_test_client/serverpod_offline_sync_test_client.dart';
import 'package:test/test.dart';

import '../integration/test_tools/client_session.dart';
import 'framework/dst_random.dart';
import 'framework/dst_snapshot.dart';
import 'framework/dst_world.dart';

void main() {
  initTestClientSession(createSessionPerTest: false);

  test(
    'Given an empty synchronized scalar table, '
    'when the DST authors a generated batch, '
    'then both typed rows and their accepted authored facts survive bootstrap.',
    () async {
      final random = DstRandom(18);
      final ids = DstIds(random);
      final space = ids.next();
      final source = await _replica(ids, space);
      final target = await _replica(ids, space);
      final operations = DstOperations(random, ids);

      final outcome = await operations.apply(
        source,
        space,
        table: DstTable.types,
        action: DstAction.insertBatch,
      );
      await target.merge(await source.collect(space), space);

      expect(outcome, DstOperationOutcome.applied);
      final rows = await Types.db.find(source.session);
      expect(rows, hasLength(2));
      expect(
        {for (final row in await Types.db.find(target.session)) row.id: _values(row)},
        {for (final row in rows) row.id: _values(row)},
      );
      expect(
        operations.oracle.validate(await DstSnapshot.capture(target), space),
        isEmpty,
      );
    },
  );

  for (final enumValue in [TypesEnum.beta, null]) {
    test(
      'Given a row containing every scalar type and nullable values, '
      'when the DST updateWhere adapter replaces all fields with enum ${enumValue?.name ?? 'null'} and clears optional text and UUID, '
      'then the ORM stores the supplied Dart values without JSON type leakage.',
      () async {
        final ids = DstIds(DstRandom(19));
        final space = ids.next();
        final replica = await _replica(ids, space);
        final row = _row(ids.next());
        await replica.withReplicaClock(
          () => replica.session.db.transactionForUser(
            space,
            (tx) => Types.db.insertRow(replica.session, row, transaction: tx),
          ),
        );
        final updated = row.copyWith(
          aBool: false,
          aDateTime: DateTime.utc(2030, 5, 6, 1, 2, 3, 456),
          aText: 'updated',
          anInt: -7,
          anInt64: BigInt.parse('-9007199254740993'),
          aReal: -12.625,
          aBlob: ByteData.sublistView(Uint8List.fromList(List.generate(16, (i) => i))),
          anEnum: enumValue,
          optionalText: null,
          optionalUuid: null,
        );
        final values = _values(updated);
        await replica.withReplicaClock(
          () => replica.session.db.transactionForUser(
            space,
            (tx) => DstTable.types.model.updateWhere(
              replica.session,
              {row.id!},
              values,
              tx,
            ),
          ),
        );

        expect(_values((await Types.db.findById(replica.session, row.id!))!), values);
      },
    );
  }

  test(
    'Given two replicas sharing a typed row, '
    'when concurrent writes overlap on its text and change separate scalar fields, '
    'then reversed duplicate delivery and fresh bootstrap preserve the field winners.',
    () async {
      final ids = DstIds(DstRandom(20));
      final space = ids.next();
      final left = await _replica(ids, space);
      final right = await _replica(ids, space);
      final fresh = await _replica(ids, space);
      final row = _row(ids.next());
      await left.withReplicaClock(
        () => left.session.db.transactionForUser(
          space,
          (tx) => Types.db.insertRow(left.session, row, transaction: tx),
        ),
      );
      await right.merge(await left.collect(space), space);
      final leftUpdate = row.copyWith(
        aBool: false,
        aDateTime: DateTime.utc(2027, 3, 4, 5, 6, 7, 890),
        aText: 'left',
        anInt64: BigInt.parse('-9007199254740993'),
        aBlob: ByteData.sublistView(Uint8List.fromList(List.filled(16, 255))),
      );
      final rightUpdate = row.copyWith(
        aText: 'right',
        anInt: -42,
        aReal: -1.125,
        anEnum: TypesEnum.gamma,
        optionalText: null,
        optionalUuid: null,
      );
      await left.withReplicaClock(
        () => left.session.db.transactionForUser(
          space,
          (tx) => Types.db.updateRow(
            left.session,
            leftUpdate,
            columns: (t) => [t.aBool, t.aDateTime, t.aText, t.anInt64, t.aBlob],
            transaction: tx,
          ),
        ),
      );
      await right.withReplicaClock(
        () => right.session.db.transactionForUser(
          space,
          (tx) => Types.db.updateRow(
            right.session,
            rightUpdate,
            columns: (t) => [
              t.aText,
              t.anInt,
              t.aReal,
              t.anEnum,
              t.optionalText,
              t.optionalUuid,
            ],
            transaction: tx,
          ),
        ),
      );
      final leftBefore = await DstSnapshot.capture(left);
      final rightBefore = await DstSnapshot.capture(right);
      final textKey = ('types', row.id!, 'aText');
      final textWinner =
          leftBefore.fieldHlcs[textKey]!.compareTo(rightBefore.fieldHlcs[textKey]!) > 0
          ? 'left'
          : 'right';
      final expected = _values(
        leftUpdate.copyWith(
          aText: textWinner,
          anInt: rightUpdate.anInt,
          aReal: rightUpdate.aReal,
          anEnum: rightUpdate.anEnum,
          optionalText: null,
          optionalUuid: null,
        ),
      );
      final fromLeft = await left.collect(space);
      final fromRight = await right.collect(space);

      await left.merge(fromRight, space);
      await right.merge(fromLeft, space);
      await right.merge(fromRight, space);
      await left.merge(fromLeft, space);
      await left.merge(fromRight, space);
      await right.merge(fromLeft, space);
      await fresh.merge(await left.collect(space), space);

      for (final replica in [left, right, fresh]) {
        expect(_values((await Types.db.findById(replica.session, row.id!))!), expected);
      }
    },
  );
}

Types _row(UuidValue id) => Types(
  id: id,
  aBool: true,
  aDateTime: DateTime.utc(2026, 1, 1),
  aText: 'initial',
  anInt: 1,
  anInt64: BigInt.parse('9007199254740993'),
  aReal: 1.25,
  aBlob: ByteData.sublistView(Uint8List.fromList([0, 128, 255])),
  anEnum: TypesEnum.alpha,
  optionalText: 'present',
  optionalUuid: const UuidValue.raw('660e8400-e29b-41d4-a716-446655440000'),
);

Map<String, dynamic> _values(Types row) => {
  ...row.toJson()
    ..remove('id')
    ..remove('spaceId')
    ..remove('__className__'),
  'anEnum': row.anEnum?.toJson(),
  'optionalText': row.optionalText,
  'optionalUuid': row.optionalUuid?.toJson(),
};

Future<DstReplica> _replica(DstIds ids, UuidValue space) async => DstReplica.create(
  name: 'typed',
  spaceUuids: [space],
  nodeUuid: ids.next(),
  clock: DstClock().clock,
);
