# DST harness hardening

The harness uses isolated SQLite replicas, the production ORM, collector and
merge boundary. Production packages are unchanged. Replay is exact within a
revision; correcting generator inputs can change schedules between revisions.

## Portable oracle and independent evidence

Snapshots compare all schema columns, including omitted nullable JSON values,
portable insertion and effective field HLCs, authored values, projection reasons,
and tombstone generation/HLC/reason. Absent field metadata inherits the insertion
clock; an explicit field at that same clock is equivalent. Replica-local integer
IDs and space/node checkpoints are not portable facts.

The generator retains submitted values before each ORM write and verifies them
after commit. Full-row projected passthrough preserves its attempted value/HLC.
The oracle admits only the local before/after clock delta after these checks;
an unrelated write cannot bless prior merged corruption. Controlled initial
fixtures may initialize it explicitly. At quiescence, accepted insertion, field
and tombstone facts must survive LWW merging. Local FK side effects are retained
from the acknowledged delta; real DB scenarios cover their semantics rather
than duplicating a general FK/unique planner.

Raw SQLite ORM controls independently establish persisted insert defaults and
explicit narrowed null updates. Existing-row reinsertion uses update semantics,
while visible upsert applies insert defaults; separate controls cover each path.
A visibility rule rejects hiding a live row with no authored outbound references.
It does not arbitrate general FK fixed points or unique winners. Hidden
unrepairable SET DEFAULT references remain legal, and FK-before-unique rules are
preserved. Bootstrap compares export plus merge/projection against the source;
it is not independent proof against identical corruption on both sides.

## Incremental validation

Commands run from `test/serverpod_offline_sync_test_server` with
`/home/msoares/fvm/versions/3.35.3/bin/cache/dart-sdk/bin/dart` (Dart 3.12.2).
Implementation logs are in `/tmp/dst-fix-logs/`.

- Oracle increment: `dart test test/dst/dst_authored_oracle_test.dart
  test/dst/dst_operations_test.dart test/dst/dst_projection_oracle_test.dart
  --concurrency=1 --reporter expanded`: **29 passed**;
  `issue1-commit-controls.log`.
- Initial full untagged DST run: **47 passed, 1 failed, 3 tagged-suite skips**;
  `issue1-focused-v3.log`. The original 400-operation test reaches a projected
  `unique_set_default_child.updateWhere` whose explicit null is not retained.
  This remains a failure for investigation, not an expected refusal. Its timeout
  increased to 2 minutes because the pre/post database observations add work;
  assertions are unchanged.
- Seed 114 / 40 rounds / overlapping spaces exposes membership-wide generator
  reads selecting another space's row (`issue1-seed114-v3.log`). This is a harness
  selection defect; correcting it belongs to the rejection-handling increment.

The starting revision's seed 114 / 200-round engine failures remain deferred:
empty-replica bootstrap violates `unique.spaceId,name`, and overlapping spaces
rematerialize a mixed unique FK name differently. Collector interleaving bug #84
is outside this task. No engine failure is skipped or converted to success.
