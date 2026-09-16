import 'package:test/test.dart';

import 'framework/dst_world.dart';

void main() {
  test(
    'Given the generated synchronized model catalog, '
    'when the DST model population is enumerated, '
    'then every synchronized table is authored and compared.',
    () {
      expect(
        DstTable.values.map((table) => table.tableName).toSet(),
        dstSyncTables.map((table) => table.tableName).toSet(),
      );
      expect(dstModels.keys.toSet(), DstTable.values.toSet());
    },
  );

  test(
    'Given the simulated foreign key population, '
    'when its reference columns and delete actions are enumerated, '
    'then every edge targets id and has an action the refusal predictor models.',
    () {
      expect(
        dstForeignKeys.map((edge) => edge.parentColumn).toSet(),
        {'id'},
        reason: 'Extend DstRejection._children before adding other target columns.',
      );
      expect(
        dstForeignKeys.map((edge) => edge.action).toSet(),
        everyElement(isIn({'cascade', 'noAction', 'setNull', 'setDefault'})),
        reason: 'Extend DstRejection.deleteReasons for new delete actions.',
      );
    },
  );
}
