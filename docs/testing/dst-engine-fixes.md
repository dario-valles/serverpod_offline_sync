# Captured DST engine regressions

The field-touch oracle correction is separate (`77bb1ef`): omitting
`columns`/`updateColumns` intentionally touches unchanged fields.

## Validation method

Use Dart 3.12.2 at `/home/msoares/fvm/versions/3.44.4/bin/cache/dart-sdk/bin/dart`.
Run `dart run benchmark/run.dart --ci --rows=200` from the repository root,
serially with correctness tests. Each measurement excludes fixture preparation.
Logs for this review are in `/tmp/offline-sync-engine-fixes/`.
Timings are finite local samples, with JIT and machine variation; query counts
help distinguish additional database work from timing noise.

| Operation | Baseline `77bb1ef` (ms) | After #138 (ms) | After #139 (ms) |
| --- | ---: | ---: | ---: |
| CRUD insert | 82.81 | 84.81 | 117.17 |
| CRUD update | 449.09 | 470.52 | 476.27 |
| Upsert insert | 107.43 | 117.22 | 116.36 |
| Upsert update | 482.84 | 459.21 | 447.92 |
| CRUD delete | 81.32 | 77.50 | 80.66 |
| Merge insert | 191.23 | 217.45 | 205.32 |
| Merge update | 110.06 | 116.30 | 123.07 |
| Merge delete | 81.92 | 86.46 | 93.17 |
| Merge mixed | 126.27 | 137.69 | 146.74 |
| Merge unique conflict | 309.13 | 316.29 | 342.58 |
| Merge original default parent delete/restore | 6.83 | 7.22 | 7.66 |
| Merge default parent delete/restore | 4.35 | 4.69 | 4.54 |
| Merge FK chain insert | 260.07 | 249.89 | 250.34 |
| Merge FK chain delete | 68.76 | 66.80 | 66.62 |

## #138: Preserve identifier-shaped text

Projection decodes UUIDs using column types; arbitrary text retains its exact
contents and letter case. The same normalization applies when finding records
waiting to reclaim a unique UUID. Outbound attempted values retain their types.

The new independent text regression failed before the fix, then passed with
the three captured text cases and an actual UUID reclaim control. The broader
CRUD/merge/sync run passed 731 tests; after the additional UUID closure correction,
the six focused type/reclaim tests passed. Analyzer and whitespace checks passed.

The unique-conflict benchmark retained 459 queries and 3,202 returned rows per
200-change batch. Repeated existing merge-insert, unique-conflict, and upsert-insert
benchmarks showed startup variation: merge insert 252.88/175.05/165.35 ms,
unique conflict 353.20/303.03/299.11 ms, and upsert insert 117.29/113.18/110.43 ms.
The initial slower merge-insert sample did not persist after warmup. No additional
queries were introduced on these measured paths. Full-run logs are
`baseline-benchmark.log` and `text-benchmark.log`; repeats are `text-repeat.log`.

## #139: Preserve new values accepted by upsert

The upsert preparation retains the projection snapshot it already computes.
Accepted updates use that snapshot to distinguish new authored values from
unchanged displayed alternatives. Explicit `updateColumns` can author null;
rows excluded by `updateWhere` contribute no new facts. Non-primary conflict
keys use an indexed lookup to include the actual existing row in the snapshot.

Three new integration cases failed before the fix: full-row and narrowed saves
to a new value, and explicitly clearing a projected claim. The focused upsert,
CRUD and insertion/touch-contract run passed 58 tests. All five dedicated cases
passed after adding the non-primary conflict-key control. Analyzer passed.

The affected 200-row upsert benchmarks measured 116.36 ms for insertion and
447.92 ms for updates, versus 117.22/459.21 ms after #138 (-0.7%/-2.5%). The
primary-key fast paths retain their query structure. Other benchmark timings
varied, including the unchanged CRUD-insert path; these samples do not establish
a timing guarantee. Storage sizes were unchanged. See `upsert-benchmark.log`,
`upsert-red.log`, `upsert-green.log`, and `upsert-final.log`.
