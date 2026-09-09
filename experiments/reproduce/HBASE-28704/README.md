# HBASE-28704 — live reproduction

*The expired snapshot can be read by CopyTable or ExportSnapshot.*

Buggy `0e65ff6aab`, fixed `60d6ebdcf3` (branch-2, 2.5.10-SNAPSHOT). Donor for the
runtime experiment is **HBASE-27671** (147 verified invariants).

## What the bug is

`SnapshotDescriptionUtils.isExpiredSnapshot(ttl, creationTime, now)` decides whether a
snapshot is past its TTL. The fix adds that check in two places that did not have it:

| path | class | reached by |
|---|---|---|
| scanner copy | `RestoreSnapshotHelper.copySnapshotForScanner` | `TableSnapshotScanner`, `TableSnapshotInputFormat`, `CopyTable --snapshot` |
| export | `ExportSnapshot.verifySnapshot` | `hbase ... ExportSnapshot` |

Both then throw `SnapshotTTLExpiredException`.

## Why the trigger is `TableSnapshotScanner`, not `Admin.restoreSnapshot`

`Admin.restoreSnapshot` and `Admin.cloneSnapshot` are **not** triggers for this bug.
HBASE-27671 — the donor of this very pair — put a TTL check in `RestoreSnapshotProcedure`
and `CloneSnapshotProcedure`, and 27671 is present in **both** builds here. Driving that
path would measure the donor's fix and report a difference of zero.

The JIRA's own two triggers, `CopyTable` and `ExportSnapshot`, are MapReduce jobs. The
third guarded path, `copySnapshotForScanner`, is reachable without a job runner through
`TableSnapshotScanner` — so that is the primary probe, and `ExportSnapshot` and
`CopyTable` are run afterwards as tool-level confirmation.

**Both classes the probe drives are `@InterfaceAudience.Private`**: `TableSnapshotScanner`
(despite living in `org.apache.hadoop.hbase.client`) and `RestoreSnapshotHelper` itself.
The probe is therefore calling HBase internals directly, not exercising a user-facing API.
The realistic entry points are `CopyTable --snapshot --bulkload`, which reaches the same
code via `TableMapReduceUtil.initTableSnapshotMapperJob` → `TableSnapshotInputFormat`, and
`ExportSnapshot`. Both are run here and both reproduce the bug — but neither yields OKLib
data (see the results section).

`SnapshotProbe` therefore makes three checks:

| | what | buggy | fixed |
|---|---|---|---|
| **A** | `RestoreSnapshotHelper.copySnapshotForScanner` | `READ_EXPIRED_SNAPSHOT` | `REFUSED_TTL_EXPIRED` |
| **B** | `TableSnapshotScanner` row count | `READ_EXPIRED_SNAPSHOT rows=N` | `REFUSED_TTL_EXPIRED` |
| **C** | `Admin.cloneSnapshot` — **control** | `REFUSED_TTL_EXPIRED` | `REFUSED_TTL_EXPIRED` |

C differing between sides means the builds are wrong. C succeeding means 27671 is
missing. Only A and B are allowed to separate the two builds.

## Topology

Standalone: HMaster + RegionServer + ZooKeeper in one JVM, `hbase.rootdir` on the local
filesystem. Snapshot handling is filesystem work — it needs neither HDFS nor a second
node. The one config that matters is `hbase.master.cleaner.snapshot.interval`, pushed to
a day so `SnapshotCleanerChore` cannot delete the expired snapshot before the probe
reads it.

## Where OKLib attaches, and why that is different here

HDFS-16547 and ZOOKEEPER-3531 both had the bug inside a long-lived daemon. This one does
not: `copySnapshotForScanner` runs in a **short-lived client JVM**. So OKLib is attached
in two places, each with its own `ok.ok_root_abs_path`:

- **HMaster** — via `conf/samples/hb-patches/install_hbase.patch` against `bin/hbase`
  (`MainWrapper` has to become the main class, which `HBASE_OPTS` cannot do).
- **the probe JVM** — flags passed directly on its command line by the trigger, the
  ZK-3531 idiom. `LINGER` holds the process open after the probe so the periodic
  checker gets rounds in; without it the JVM can exit before one check window closes.

A structural consequence worth recording before any numbers are collected: the offline
`check_trace` ran everything inside one MiniCluster JVM, so master-side and client-side
events shared an event stream. Live they do not. Of the 9 invariants the offline run
detected for the RestoreSnapshot variant, two name master-only classes
(`TaskMonitor`, `master.snapshot.SnapshotManager`) and can never fire in the probe JVM,
while the other seven (`CommonFSUtils`, `HFileLink`, `SnapshotRegionManifest`, `Bytes`,
`EnvironmentEdgeManager`) sit on the client read path. Any live/offline gap has to be
read against that split, not treated as a detection failure.

## Order of use

```bash
ok=/localtmp/julian/OKLib; cd $ok/experiments/reproduce/HBASE-28704

# 1. build both sides (~1 h)
./install_HBASE-28704.sh $ok /localtmp/julian/hbase both

# 2. reproduction, no OKLib anywhere -- must differ before instrumentation exists
./uninstall_oklib_HBASE-28704.sh all
./trigger_HBASE-28704.sh $ok buggy
./trigger_HBASE-28704.sh $ok fixed

# 3. attach OKLib WITHOUT touching the bug, then re-run both
./install_oklib_HBASE-28704.sh $ok buggy && WITH_OKLIB=1 ./trigger_HBASE-28704.sh $ok buggy
./install_oklib_HBASE-28704.sh $ok fixed && WITH_OKLIB=1 ./trigger_HBASE-28704.sh $ok fixed

# 4. cleanup
./cleanup_HBASE-28704.sh all
```

Step 3 needs **buggy twice**. HDFS-16547 is the precedent: 15 apparently buggy-only
invariants collapsed to a noise floor of 15 and a signal of 2 once a same-build control
existed. A single buggy run against a single fixed run cannot tell signal from noise.

## Caveats carried in

- The donor's `verified_invs` is the **3 Jun verify, pre-`70963be`**. Not degenerate
  (mixed pass/fail, unlike HDFS-2484's) but not re-verified. Any detection is
  provisional until it is.
- The donor is 2.5.3-era (`620ab79b`); the target is 2.5.10-SNAPSHOT. Cross-version.
- Offline, the detections were almost all `OpHappenBeforeOp` over `Bytes`, `TableName`
  and `CommonFSUtils` — **weak-symbolic** under `valuable-invariant-tiering.md`, not the
  TTL/expiry semantic the bug is about.

---

## Results, 2026-09-05

### Reproduction, no OKLib attached

| check | buggy `0e65ff6aab` | fixed `60d6ebdcf3` |
|---|---|---|
| A `copySnapshotForScanner` | `READ_EXPIRED_SNAPSHOT` | `REFUSED_TTL_EXPIRED` |
| B `TableSnapshotScanner` | `READ_EXPIRED_SNAPSHOT rows=2000` | `REFUSED_TTL_EXPIRED` |
| ExportSnapshot | exit 0, 6 files written | exit 1, `SnapshotTTLExpiredException`, 0 files |
| CopyTable `--snapshot --bulkload` | exit 0 | exit 1, `SnapshotTTLExpiredException` |
| C `cloneSnapshot` (control) | `REFUSED_TTL_EXPIRED` | `REFUSED_TTL_EXPIRED` |

The control holding equal across both sides is what makes the rest trustworthy: it shows
HBASE-27671's guard is present and identical in both builds, so nothing above is the
donor's fix leaking into the measurement.

### OKLib attached, bug not fixed

**One buggy run, partial.** It was killed after the probe to free CPU for the donor
re-verify, so `ExportSnapshot` and `CopyTable` never ran under instrumentation, and the
**fixed side was never run with OKLib at all**. What is established: OKLib attaches to
both the HMaster and the client JVM, loads all 147 invariants, checks actively, and does
not perturb the bug -- `PROBE_A`, `PROBE_B` and `PROBE_C` came back identical to the
uninstrumented run.

What is NOT established, and is a stated verification condition: that the **fixed** side
still behaves correctly with OKLib attached. Without it the buggy/fixed comparison is not
meaningful. That run belongs to the detection experiment below and has to happen after
re-verify anyway, with the restaged invariants.

Both JVMs were genuinely checking:

| JVM | loaded | pass | fail | inactive | check rounds |
|---|---|---|---|---|---|
| HMaster | 147 | 57 | 76 | 14 | 189 |
| probe (client) | 147 | 13 | 17 | **117** | -- |

**117 of 147 invariants are inactive in the probe JVM.** That is the offline/live gap
predicted above, now measured: the donor's invariants were inferred inside a single
MiniCluster JVM where master-side and client-side events shared one stream, and this bug
executes in a client process. It is a property of the experiment, not a detection failure.

### Not yet done

- **fixed side under OKLib** -- never run; required before any comparison is valid.
- Runtime detection numbers. Needs **buggy x2 + fixed x1** -- a single buggy run cannot
  separate signal from noise (HDFS-16547: apparent signal 15, noise floor 15, real
  signal 2). The one instrumented run so far also predates the `OK_ROOT_OVERRIDE` fix,
  so its tool JVMs would have shared the master's `ok_root`; redo it with current scripts.
- Donor re-verify, started detached 2026-09-05 ~12:10, ~8.3 h. Until it lands, every
  number here rests on the 3 Jun pre-`70963be` donor set.
