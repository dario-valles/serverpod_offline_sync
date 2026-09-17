import 'package:serverpod_offline_sync_server/serverpod_offline_sync_server.dart';
import 'package:serverpod_offline_sync_test_client/serverpod_offline_sync_test_client.dart';
import 'package:test/test.dart';

import 'framework/dst_snapshot.dart';
import 'framework/dst_world.dart';

void main() {
  const space = UuidValue.raw('660e8400-e29b-41d4-a716-446655440000');
  const child = UuidValue.raw('660e8400-e29b-41d4-a716-446655440001');
  const attempted = UuidValue.raw('660e8400-e29b-41d4-a716-446655440002');
  const fallback = UuidValue.raw('660e8400-e29b-41d4-a716-446655440003');

  for (final scenario in [
    (
      given: 'a set-null reference recorded with a set-default reason',
      table: DstTable.town,
      column: 'mayorId',
      domain: null,
      reason: CrdtProjectionReason.foreignKeySetDefault,
      childVisible: true,
      parentVisible: false,
      expected:
          'town/$child.mayorId has reason foreignKeySetDefault, '
          'which is impossible on a setNull edge',
    ),
    (
      given: 'a unique release whose domain still equals its preserved claim',
      table: DstTable.uniqueSetNullChild,
      column: 'parentId',
      domain: attempted,
      reason: CrdtProjectionReason.uniqueConflict,
      childVisible: true,
      parentVisible: true,
      expected:
          'unique_set_null_child/$child.parentId holds $attempted equal '
          'to the authored value it is preserving (reason: uniqueConflict)',
    ),
    (
      given: 'a set-null repair retaining a different non-null reference',
      table: DstTable.town,
      column: 'mayorId',
      domain: fallback,
      reason: CrdtProjectionReason.foreignKeySetNull,
      childVisible: true,
      parentVisible: false,
      expected: 'town/$child.mayorId is set-null but its domain value is $fallback',
    ),
    (
      given: 'a set-default repair pointing to a visible non-default town',
      table: DstTable.company,
      column: 'townId',
      domain: fallback,
      reason: CrdtProjectionReason.foreignKeySetDefault,
      childVisible: true,
      parentVisible: false,
      expected:
          'company/$child.townId is set-default but its domain value is '
          '$fallback, not the column default $dstDefaultTownId',
    ),
    (
      given: 'a set-null override whose authored parent is visible in the same space',
      table: DstTable.town,
      column: 'mayorId',
      domain: null,
      reason: CrdtProjectionReason.foreignKeySetNull,
      childVisible: true,
      parentVisible: true,
      expected:
          'town/$child.mayorId keeps a foreignKeySetNull override while '
          'its target $attempted is visible in the same space',
    ),
    (
      given: 'an unrepairable reference whose child is still visible',
      table: DstTable.uniqueSetDefaultChild,
      column: 'parentId',
      domain: null,
      reason: CrdtProjectionReason.foreignKeyMissingParent,
      childVisible: true,
      parentVisible: false,
      expected:
          'unique_set_default_child/$child.parentId is unrepairable but the row is still visible',
    ),
  ]) {
    test(
      'Given a detector snapshot containing ${scenario.given}, '
      'when projection purity checks the preserved-value record, '
      'then it reports exactly that invalid projection.',
      () {
        final snapshot = _projection(
          space: space,
          child: child,
          table: scenario.table,
          column: scenario.column,
          domain: scenario.domain,
          attempted: attempted,
          reason: scenario.reason,
          childVisible: scenario.childVisible,
          parentVisible: scenario.parentVisible,
          additionalVisibleParent: fallback,
        );

        final violations = DstOracle.projectionPurity(snapshot);

        expect(violations, [
          (property: 'projectionPurity', detail: scenario.expected),
        ]);
      },
    );
  }

  for (final scenario in [
    (
      given: 'a nullable reference to a hidden parent repaired to null',
      table: DstTable.town,
      column: 'mayorId',
      domain: null,
      reason: CrdtProjectionReason.foreignKeySetNull,
      childVisible: true,
      parentVisible: false,
      additionalVisibleParent: null,
    ),
    (
      given: 'a reference to a hidden town repaired to the visible default town',
      table: DstTable.company,
      column: 'townId',
      domain: dstDefaultTownId,
      reason: CrdtProjectionReason.foreignKeySetDefault,
      childVisible: true,
      parentVisible: false,
      additionalVisibleParent: dstDefaultTownId,
    ),
    (
      given:
          'a hidden child preserving an unrepairable town claim with no available default',
      table: DstTable.uniqueSetDefaultChild,
      column: 'parentId',
      domain: null,
      reason: CrdtProjectionReason.foreignKeyMissingParent,
      childVisible: false,
      parentVisible: false,
      additionalVisibleParent: null,
    ),
    (
      given: 'a visible unique loser released to null despite its parent being visible',
      table: DstTable.uniqueSetNullChild,
      column: 'parentId',
      domain: null,
      reason: CrdtProjectionReason.uniqueConflict,
      childVisible: true,
      parentVisible: true,
      additionalVisibleParent: null,
    ),
    (
      given: 'a hidden unique row released to null despite its parent being visible',
      table: DstTable.uniqueSetNullChild,
      column: 'parentId',
      domain: null,
      reason: CrdtProjectionReason.hiddenUniqueRelease,
      childVisible: false,
      parentVisible: true,
      additionalVisibleParent: null,
    ),
  ]) {
    test(
      'Given a detector snapshot containing ${scenario.given}, '
      'when projection purity checks the preserved-value record, '
      'then it accepts the ${scenario.reason.name} projection.',
      () {
        final snapshot = _projection(
          space: space,
          child: child,
          table: scenario.table,
          column: scenario.column,
          domain: scenario.domain,
          attempted: attempted,
          reason: scenario.reason,
          childVisible: scenario.childVisible,
          parentVisible: scenario.parentVisible,
          additionalVisibleParent: scenario.additionalVisibleParent,
        );

        expect(DstOracle.projectionPurity(snapshot), isEmpty);
      },
    );
  }
}

/// Mechanical detector input only. Every relevant value is supplied by the
/// scenario, and no damaged row or projection is persisted or merged.
DstSnapshot _projection({
  required UuidValue space,
  required UuidValue child,
  required DstTable table,
  required String column,
  required UuidValue? domain,
  required UuidValue attempted,
  required CrdtProjectionReason reason,
  required bool childVisible,
  required bool parentVisible,
  required UuidValue? additionalVisibleParent,
}) {
  final edge = dstForeignKeys.singleWhere(
    (edge) => edge.child == table && edge.column == column,
  );
  return DstSnapshot(
    rows: {
      edge.parent.tableName: {
        attempted: (spaceUuid: space, columns: {}, visible: parentVisible),
        ?additionalVisibleParent: (spaceUuid: space, columns: {}, visible: true),
      },
      table.tableName: {
        child: (spaceUuid: space, columns: {column: domain}, visible: childVisible),
      },
    },
    projections: {
      (table.tableName, child, column): (
        attemptedValue: attempted,
        projectionReason: reason,
      ),
    },
    causalLengths: {},
  );
}
