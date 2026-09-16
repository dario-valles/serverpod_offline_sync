import 'package:serverpod_offline_sync_test_client/serverpod_offline_sync_test_client.dart';

import 'dst_authored.dart';
import 'dst_snapshot.dart';
import 'dst_world.dart';

/// Refusals justified by the concrete pre-operation graph and selected rows.
/// This predicts only local refusal conditions, not merge-time visibility or
/// unique winners. Supported competing unique claims must always commit.
class DstRejection {
  DstRejection(this.before, this.space);

  final DstSnapshot before;
  final UuidValue space;
  final Set<(DstTable, UuidValue)> deleting = {};

  /// This input namespace is reserved by the public unique-text contract.
  /// Keep the prediction independent of the production validator.
  Iterable<String> reservedValueReasons(DstWriteEvidence writes) sync* {
    final suffix = RegExp(
      '__(conflict|hidden|park)__[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-'
      r'[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    );
    for (final MapEntry(key: key, value: value) in writes.values.entries) {
      if (value is! String || !suffix.hasMatch(value)) continue;
      if (!dstUniqueIndexes.any(
        (index) => index.table.tableName == key.$1 && index.columns.contains(key.$3),
      )) {
        continue;
      }
      yield 'Reserved generated unique value for ${key.$1}.${key.$3}: $value';
    }
  }

  void delete(DstTable table, Iterable<UuidValue> ids) {
    deleting.addAll(ids.map((id) => (table, id)));
    var grew = true;
    while (grew) {
      grew = false;
      for (final edge in dstForeignKeys.where((edge) => edge.action == 'cascade')) {
        for (final child in _children(edge)) {
          grew = deleting.add((edge.child, child)) || grew;
        }
      }
    }
  }

  Iterable<UuidValue> _children(DstForeignKey edge) sync* {
    for (final row in (before.visible[edge.child.tableName] ?? {}).entries) {
      if (row.value.spaceUuid != space) continue;
      final parent = row.value.columns[edge.column];
      if (parent == null) continue;
      if (deleting.contains((
        edge.parent,
        UuidValue.withValidation(parent.toString()),
      ))) {
        yield row.key;
      }
    }
  }

  /// Definite blockers exclude children also in the cascade delete closure:
  /// their order can legitimately remove the blocker before its parent.
  Iterable<String> deleteReasons({bool definiteOnly = false}) sync* {
    for (final edge in dstForeignKeys) {
      final children = _children(
        edge,
      ).where((id) => !definiteOnly || !deleting.contains((edge.child, id)));
      if (children.isEmpty) continue;
      final parent = edge.parent.tableName;
      final child = '${edge.child.tableName}.${edge.column}';
      if (edge.action == 'noAction') {
        yield 'Cannot delete $parent row because $child references it.';
      }
      if (edge.action == 'setNull' && !edge.nullable) {
        yield 'NOT NULL constraint failed: $child,';
      }
      if (edge.action == 'setDefault') {
        final target = edge.defaultValue == null
            ? null
            : before.lookupVisible(edge.parent, edge.defaultValue!);
        final valid = edge.defaultValue == null
            ? edge.nullable
            : target != null &&
                  target.spaceUuid == space &&
                  !deleting.contains((edge.parent, edge.defaultValue!));
        if (!valid) {
          yield 'Cannot delete $parent row because $child has no legal set-default target.';
        }
      }
    }
  }

  bool accepts(String message, DstWriteEvidence writes) {
    if (reservedValueReasons(writes).contains(message)) return true;
    if (deleteReasons().any(message.contains)) return true;
    // Restoring a hidden row can resubmit a retained reference whose target
    // is unavailable. Match the actual submitted column and target, never an
    // arbitrary FK/SQL exception. Generated fresh references are space-local.
    for (final entry in writes.values.entries) {
      if (entry.value == null) continue;
      for (final edge in dstForeignKeys.where(
        (edge) => edge.child.tableName == entry.key.$1 && edge.column == entry.key.$3,
      )) {
        final id = UuidValue.withValidation(entry.value.toString());
        final target = before.lookupVisible(edge.parent, id);
        if (target != null && target.spaceUuid == space) continue;
        if (message.contains(
          'Cannot reference deleted row '
          '${edge.parent.tableName}.${edge.parentColumn} = $id.',
        )) {
          return true;
        }
      }
    }
    return false;
  }
}
