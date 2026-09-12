# DST harness hardening

The harness uses isolated SQLite replicas, the production ORM, collector and
merge boundary. Production packages are unchanged. Replay is exact within a
revision; correcting generator inputs can change schedules between revisions.

## Portable oracle and independent evidence

Snapshots compare all schema columns, including omitted nullable JSON values,
portable effective field HLCs, authored values, projection reasons,
and tombstone generation/HLC/reason. Absent field metadata inherits the insertion
clock; an explicit field at that same clock is equivalent. Replica-local integer
IDs and space/node checkpoints are not portable facts.

The generator retains submitted values before each ORM write and verifies them
after commit. Full-row projected passthrough preserves its attempted value/HLC.
The oracle admits only the local before/after clock delta after these checks;
an unrelated write cannot bless prior merged corruption. Controlled initial
fixtures may initialize it explicitly. At quiescence, accepted row identities/spaces, effective field facts
and real tombstones must survive LWW merging. Local FK side effects are retained
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

## Concrete operations and refusals

All generator reads, including parent selection, use the public `spaceEquals`
filter. Production space-scoped reads are membership-wide, so a transaction's acting
space alone does not constrain those reads. Admin snapshots remain unfiltered.
Refusal prediction follows the selected row IDs through the cascade closure;
no-action children, non-null SET NULL children, and unavailable defaults justify
only their exact exceptions. A default deleted in the same batch is unavailable.
Definite blockers also fail an unexpected successful return. Successful primary
delete/restore intents must advance the authored tombstone with the right parity.

Expected refusals compare the whole domain/authored/projection/tombstone state,
explicit field-clock representation, and persisted space-node progress before
and after the transaction. Arbitrary UNIQUE and FOREIGN KEY errors propagate.
Real SQLite trigger fault injection checks that path; ordinary competing unique
insert/batch/update regressions verify supported operations really commit.

- Rejection increment: `dart test test/dst/dst_rejection_test.dart
  test/dst/dst_operations_test.dart --concurrency=1 --reporter expanded`:
  **21 passed** (`issue2-focused.log`).
- `dart analyze test/dst`: **no issues** (`issue2-analyze.log`).

## Populated profiles and observable activity

`DST_PROFILE=sparse|populated|mixed` and `DST_GRAPH_WIDTH` accompany seed/rounds in
replay messages. Mixed alternates even populated and odd sparse seeds. Populated
worlds create all 32 tables and 28 authored FK edges, cycles, competing unique
writes, a verified tuple exchange, restore/redelete, retarget/detach and a blocked
delete before random scheduling. Every scripted commit runs the same structural,
causal, authoring and rollback observations as random operations. Complete
collector batches are delivered; known keys only decide whether to enqueue them.

`DST_METRICS` separates setup from scheduled activity, including on early failure.
Attempts reconcile with commits, refusals, skips and unexpected failures; an
oracle failure after a successful transaction remains a counted commit with a
validation-failure counter. Semantic observations deduplicate field/tombstone
HLC events. Authored edges/cycles are distinguished from visibility. Unique
projection coverage names columns rather than inferring which overlapping index
conflicted; a swap requires an actual different-tuple exchange.

Passing 100+ round runs require at least 30 scheduled commits and merges;
populated runs also require every declared authored FK edge and the deterministic
semantic transitions. CI now uses four mixed seeds at 200 rounds across both
topologies (4,800 scheduled attempts), replacing fifty shallow 20-round worlds
(6,000 attempts). Per-simulation and job budgets are 10 and 60 minutes. These are
configured allowances, not a measured full-depth runtime guarantee: genuine
engine failures abort the current populated/deep runs before their full budget
can be measured.

- Final workload/rejection/runner controls: `dart test
  test/dst/dst_workload_test.dart test/dst/dst_runner_test.dart
  test/dst/dst_rejection_test.dart --concurrency=1 --reporter expanded`:
  **16 passed, 1 engine failure** (`final-issue3-controls.log`). Width-two populated
  controls pass with and without the fixed default and replay exactly in isolated
  databases. Width-three seed 62 fails a supported swap after three competing
  unique claims with `unique.spaceId,name`; the failing test remains enabled.
- A 200-round width-three seed-62 replay fails during setup and correctly reports
  **35 attempts, 34 commits, 1 unexpected failure, 0 scheduled operations**
  (`issue3-width3-early-failure.log`). No stress coverage is credited to setup.
- Populated seed 114 / 40 rounds exposes `unique_set_default_child.parentId`
  UNIQUE failure on a predicate write (`issue3-populated40.log`).
- Two independent minimal real-DB diagnostic probes in
  `/tmp/dst-fix-probes/unique_authored_null_test.dart` both fail against unchanged
  production: explicitly detaching a projected unique-FK loser leaves its old
  authored reference; inserting two omitted nullable FK defaults violates the
  unique index even with the default town present (`engine-unique-probes.log`).
  These establish engine findings independently of the operation classifier.


## Reviewed normalization of equivalent insertion storage

Raw row HLC anchors are not canonical facts independently of field clocks.
`_applyMergeInsertForExistingRow` keeps an existing anchor and records newer field
HLCs, whereas local restoration touches the row anchor. A real source, existing
receiver and empty bootstrap can therefore have different raw anchors with
identical effective field values/HLCs and real restore tombstones. The added
control explicitly verifies that the raw anchors differ before asserting portable
equality. Raw anchors remain in rollback fingerprints and as the fallback for
fields without explicit clocks; changing an inherited clock remains detectable.

An independently upserted newer insertion can also be encoded as a generation-1
`userInsert` marker on an existing receiver, while the source has no tombstone.
A separate real source/receiver/bootstrap control establishes this representation
pair. Only that marker is normalized, and only when every effective field clock
already includes its HLC. Future unexplained insertion markers and every real
delete/restore tombstone remain strict. The oracle checks row identity/space and
both presence and absence of accepted visibility facts, so fabricated tombstones
cannot be treated as accepted deletes.

The raw-anchor-only failures of sparse seeds 117/118 at the prior increment were
oracle false positives, not engine defects. They are superseded by the final
normalized sweep below; no domain or effective field/tombstone discrepancy was
ignored to make that correction.

- Normalization controls: `dart test test/dst/dst_authored_oracle_test.dart
  test/dst/dst_runner_test.dart test/dst/dst_operations_test.dart
  test/dst/dst_rejection_test.dart --concurrency=1 --reporter expanded`:
  **40 passed** (`normalization-controls.log`), before the additional negative
  generation-one-marker control included in the complete final DST rerun.
