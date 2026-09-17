import 'package:serverpod_offline_sync_server/serverpod_offline_sync_server.dart';
import 'package:serverpod_offline_sync_test_client/serverpod_offline_sync_test_client.dart';
import 'package:test/test.dart';

import '../integration/test_tools/client_session.dart';
import 'framework/dst_random.dart';
import 'framework/dst_snapshot.dart';
import 'framework/dst_world.dart';

void main() {
  initTestClientSession(createSessionPerTest: false);

  test(
    'Given the captured three-record export with an authored version-5 alternative, '
    'when a fresh device imports and replays it, '
    'then bootstrap succeeds with only the surviving original claim visible.',
    () async {
      final target = await _replica();
      final changes = _capturedExport(_oldAlternative);
      await target.merge(changes, _space);
      final first = await DstSnapshot.capture(target);
      final visible = await UniqueUuid.db.find(target.session);
      expect(visible.map((row) => (row.id, row.value)), [(_c, _claim)]);
      expect(first.tombstones['unique_uuid/$_a']!.clFlag, 2);
      expect(first.tombstones['unique_uuid/$_b']!.clFlag, 2);
      expect(
        first.authoredValue(('unique_uuid', _b, 'value')),
        _oldAlternative,
      );
      await target.merge(changes.reversed.toList(), _space);
      expect(
        (await DstSnapshot.capture(target)).renderSpace(_space),
        first.renderSpace(_space),
      );
    },
  );

  test(
    'Given the same export with B claiming the new reserved conflict UUID, '
    'when a fresh device receives it repeatedly in different orders, '
    'then the authored claim is rejected before any data or progress is accepted.',
    () async {
      final target = await _replica();
      const reserved = UuidValue.raw('1384ce72-7ccf-8b5f-afc4-4fb11ac066d9');
      final changes = _capturedExport(reserved);
      final before = await DstSnapshot.capture(target);
      final spacesBefore = [
        for (final row in await OfflineSyncSpace.db.find(target.rawSession))
          row.toJson(),
      ];
      for (final batch in [changes, changes.reversed.toList(), changes]) {
        await expectLater(
          target.merge(batch, _space),
          throwsA(
            isA<OfflineSyncReservedValueException>().having(
              (e) => e.value,
              'rejected UUID',
              reserved.toString(),
            ),
          ),
        );
        final after = await DstSnapshot.capture(target);
        expect(after.renderSpace(_space), before.renderSpace(_space));
        expect(after.renderRawMetadata(), before.renderRawMetadata());
        expect([
          for (final row in await OfflineSyncSpace.db.find(target.rawSession))
            row.toJson(),
        ], spacesBefore);
      }
    },
  );
}

const _space = UuidValue.raw('00000000-0001-7bc7-b7ad-1a6c39357b70');
const _a = UuidValue.raw('00000000-0023-7ebf-9ad3-c5b5bbe5ae15');
const _b = UuidValue.raw('00000000-0079-7a97-ad58-bc62ac72c0ac');
const _c = UuidValue.raw('00000000-0080-752b-8e7c-efae8301a1fa');
const _claim = UuidValue.raw('660e8400-e29b-41d4-a716-446655440000');
const _oldAlternative = UuidValue.raw('1384ce72-7ccf-5b5f-afc4-4fb11ac066d9');
const _node2 = UuidValue.raw('00000000-0002-7ef6-82c6-177bb20eea4c');
const _node3 = UuidValue.raw('00000000-0003-7a98-a426-cc61ccab9bdb');
const _node4 = UuidValue.raw('00000000-0004-7ca0-9357-d4d0a8663894');

Future<DstReplica> _replica() => DstReplica.create(
  name: 'uuid-bootstrap',
  spaceUuids: [_space],
  nodeUuid: DstIds(DstRandom(900)).next(),
  clock: DstClock().clock,
);

/// Eight facts reduced from seed 62, populated graph width 3, 200 rounds.
/// Keep the exact IDs, claim values, and timestamps that collided before #140.
CrdtMergeSet _capturedExport(UuidValue bValue) => [
  for (final (id, value, milliseconds, counter, node) in [
    (_a, _claim, 0, 28, _node3),
    (_b, bValue, 473, 0, _node3),
    (_c, _claim, 1195, 0, _node2),
  ])
    CrdtMergeInsert(
      uuidSpaceId: _space,
      tableName: 'unique_uuid',
      uuidRowId: id,
      uuidNodeId: node,
      hlcDatetime: DateTime.utc(2026).add(Duration(milliseconds: milliseconds)),
      hlcCounter: counter,
      data: UniqueUuid(id: id, value: value),
    ),
  for (final (id, value, milliseconds, counter) in [
    (_a, _claim, 9179, 0),
    (_b, bValue, 9179, 1),
    (_c, _claim, 12229, 0),
  ])
    CrdtMergeUpdate(
      uuidSpaceId: _space,
      tableName: 'unique_uuid',
      uuidRowId: id,
      uuidNodeId: _node4,
      hlcDatetime: DateTime.utc(2026).add(Duration(milliseconds: milliseconds)),
      hlcCounter: counter,
      columnName: 'value',
      value: value,
    ),
  for (final (counter, id) in [_a, _b].indexed)
    CrdtMergeDelete(
      uuidSpaceId: _space,
      tableName: 'unique_uuid',
      uuidRowId: id,
      uuidNodeId: _node2,
      hlcDatetime: DateTime.utc(2026).add(const Duration(milliseconds: 12102)),
      hlcCounter: counter,
      clFlag: 2,
      reason: CrdtDataDeletedReason.userDelete,
    ),
];
