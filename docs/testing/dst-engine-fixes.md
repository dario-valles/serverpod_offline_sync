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

| Operation | Baseline `77bb1ef` (ms) | After #138 (ms) | After #139 (ms) | After #140 (ms) |
| --- | ---: | ---: | ---: | ---: |
| CRUD insert | 82.81 | 84.81 | 117.17 | 87.02 |
| CRUD update | 449.09 | 470.52 | 476.27 | 453.68 |
| Upsert insert | 107.43 | 117.22 | 116.36 | 114.76 |
| Upsert update | 482.84 | 459.21 | 447.92 | 480.48 |
| CRUD delete | 81.32 | 77.50 | 80.66 | 82.13 |
| Merge insert | 191.23 | 217.45 | 205.32 | 207.10 |
| Merge update | 110.06 | 116.30 | 123.07 | 119.59 |
| Merge delete | 81.92 | 86.46 | 93.17 | 89.59 |
| Merge mixed | 126.27 | 137.69 | 146.74 | 133.41 |
| Merge unique conflict | 309.13 | 316.29 | 342.58 | 310.28 |
| Merge original default parent delete/restore | 6.83 | 7.22 | 7.66 | 6.40 |
| Merge default parent delete/restore | 4.35 | 4.69 | 4.54 | 4.29 |
| Merge FK chain insert | 260.07 | 249.89 | 250.34 | 250.24 |
| Merge FK chain delete | 68.76 | 66.80 | 66.62 | 68.36 |

## #138: Preserve identifier-shaped text

Projection decodes UUIDs using column types; arbitrary text retains its exact
contents and letter case. The same normalization applies when finding records
waiting to reclaim a unique UUID. Outbound attempted values retain their types.

The new independent text regression failed before the fix, then passed with
the three captured text cases and an actual UUID reclaim control. The broader
CRUD/merge/sync run passed 731 tests; after the additional UUID closure correction,
the six focused type/reclaim tests passed. Analyzer and whitespace checks passed.

The unique-conflict benchmark retained 459 queries per 200-change batch.
Schema-correct UUID claim lookups return 3,602 rows versus 3,202 before the fix;
these include matches previously missed by the incorrectly typed lookup. Repeated existing merge-insert, unique-conflict, and upsert-insert
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
varied, including the unchanged CRUD-insert path (the plain SQLite control
also rose from 44.43 to 68.24 ms); these samples do not establish
a timing guarantee. Storage sizes were unchanged. See `upsert-benchmark.log`,
`upsert-red.log`, `upsert-green.log`, and `upsert-final.log`.

## #140: Reserve generated unique names

Unique text claims ending in `__conflict__<UUID>`, `__hidden__<UUID>`, or
`__park__<UUID>` are now invalid inputs. Local ORM writes and incoming sync facts
enforce the restriction with `OfflineSyncReservedValueException`. Full-row
passthrough of an unchanged displayed alternative retains the original claim.
Non-unique text and names that only resemble the reserved suffix remain valid.

The deterministic suffix construction is unchanged. The input check needs no
database queries and does not search occupied names for alternatives. Upsert
checks new reserved claims before its physical write can collide with another
record's generated name; accepted updates still honor their column selection.

The dedicated integration tests cover all three suffixes across insert, update,
upsert insertion/update, and predicate writes; atomic three-claim batch update
and upsert rejection; repeated/reordered invalid sync batches; and valid text
controls. Fourteen original rejection tests failed before validation was added.
The DST independently predicts only the exact reserved-value refusal and checks
rollback. Populated workloads exercise both valid ordinary-name swaps and the
rejected adoption of a generated alternative. Arbitrary SQL uniqueness errors
are still failures.

The complete untagged DST run reports **131 passed, 1 failure, 3 tagged skips**.
Eight of the nine previously failing tests now pass their applicable contracts.
The remaining 400-operation scenario reaches a later, separate failure: an `updateWhere`
assigning ordinary `claim-2` to two `unique_cascade_child` rows hits the physical
unique constraint. This is not a reserved-name input and remains an enabled
failure; this run does not establish completion of all 400 operations. The
width-three populated replay now passes. Logs: `reserved-dst.log` and
`reserved-final.log` (the latter includes the ordinary submitted values).

The final complete test-server run reports **928 passed, 1 failure, 3 tagged
skips**, with only the ordinary-name predicate-write failure above. The core
suite passed **56 tests**, all **21 dedicated reserved-name controls** passed,
and the changed-source/DST analyzer and formatting checks passed. These runs
overlap: their counts must not be added together. Logs: `final-server.log`,
`final-core.log`, `reserved-controls.log`, and `reserved-analyze.log`.

The final 200-change unique-conflict merge measured **310.28 ms**, versus
342.58 ms before the namespace restriction and 309.13 ms at the original baseline.
It still performs **459 queries** and returns 3,602 rows, unchanged from the
preceding type/upsert fixes. The namespace restriction adds no database lookup.
Upsert insert measured 114.76 ms; upsert update measured 480.48 ms (7.3% above
the preceding sample and 0.5% below the original baseline). See
`reserved-benchmark.log` for every operation and storage result.

Three follow-up samples measured unique-conflict merges at
343.70/298.28/304.46 ms (459 queries and 3,602 returned rows each), and upsert
updates at 409.83/414.52/436.05 ms. The initial slower upsert-update sample did
not persist. No sustained timing regression was observed on these measured
paths; this is bounded benchmark evidence, not an exhaustive performance guarantee.
See `reserved-repeat.log`.
