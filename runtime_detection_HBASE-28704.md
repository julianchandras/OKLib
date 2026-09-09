# Live OKLib runtime detection — HBASE-28704

OKLib in production mode against a live standalone HBase. 2026-09-07.
Third system after `runtime_detection_HDFS-16547.md` (null) and
`runtime_detection_ZK-3531.md` (detected).

**Verdict: DETECTED and tightly localized — 90 invariants against a noise floor of 0 at
n = 3, 16 of them naming the exact predicate the fix adds. Read with one structural
qualification: the detection happens in a harness client JVM we wrote and hold open,
entered through two `@InterfaceAudience.Private` classes. No long-lived JVM in an HBase
deployment executes this bug's path, so OKLib attached the way HDFS-16547 and
ZOOKEEPER-3531 were attached would detect nothing. See "Where this bug can actually be
observed in a deployment".**

## Setup

- Standalone HBase: HMaster + RegionServer + ZooKeeper in one JVM, `hbase.rootdir` on
  the local filesystem. Snapshot handling is filesystem work; no HDFS, no second node.
- Buggy `0e65ff6aab`; fixed `60d6ebdcf3` (branch-2, 2.5.10-SNAPSHOT), built as git
  worktrees so the donor repo stays free for `run_engine.sh verify`.
- Donor: **HBASE-27671, re-verified post-`70963be`** — 3799 invariants.
- OKLib attached via `conf/samples/hb-patches/install_hbase.patch` against `bin/hbase`
  (`MainWrapper` must become the main class, which `HBASE_OPTS` cannot do), with a
  **separate `ok.ok_root_abs_path` per JVM** — master, probe, export, copytable.

## The donor had to be re-verified first

| | 3 Jun, pre-`70963be` | 5 Sep, post-fix |
|---|---|---|
| verified invariants | 147 | **3799** |
| tests with an empty `pass` list | 652/1322 = **49.3%** | 104/1343 = **7.7%** |

A prior assessment called the old set "clearly not degenerate" because 660 tests had
non-empty pass lists. That was the wrong test: half the tests were losing their pass
lists. **Judge by the empty-pass fraction against a post-fix run, not by a raw count.**

## Reproduction is differential, and holds under instrumentation

`Admin.restoreSnapshot`/`cloneSnapshot` are **not** triggers for this bug — HBASE-27671,
the donor of this very pair, guards those, and it is present in both builds. Driving that
path measures the donor's fix. The no-MapReduce trigger is
`RestoreSnapshotHelper.copySnapshotForScanner`, reached through `TableSnapshotScanner`;
`cloneSnapshot` is kept as a control that must be refused on both.

**Caveat on that probe.** `TableSnapshotScanner` is `@InterfaceAudience.Private` (despite
its `org.apache.hadoop.hbase.client` package), and so is `RestoreSnapshotHelper`. The
probe calls HBase internals directly; it is not a user-facing API path.

| check | buggy | fixed |
|---|---|---|
| A `copySnapshotForScanner` | `READ_EXPIRED_SNAPSHOT` | `REFUSED_TTL_EXPIRED` |
| B `TableSnapshotScanner` | `READ_EXPIRED_SNAPSHOT rows=2000` | `REFUSED_TTL_EXPIRED` |
| ExportSnapshot | exit 0, 6 files | exit 1, `SnapshotTTLExpiredException`, 0 files |
| CopyTable `--snapshot --bulkload` | exit 0 | exit 1, `SnapshotTTLExpiredException` |
| C `cloneSnapshot` (control) | `REFUSED_TTL_EXPIRED` | `REFUSED_TTL_EXPIRED` |

Identical with OKLib attached, in all three instrumented runs.

## Detection

Distinct failing invariant ids, filtered to 0-3798:

Buggy **x3** (A/B/C) + fixed x1.

| JVM | rounds A/B/C/fixed | fail A/B/C/fixed | **noise** (pairwise across the 3 buggy) | **signal** (all 3 buggy, not fixed) |
|---|---|---|---|---|
| **probe** (harness client JVM) | 169/169/169/169 | 175/175/175/94 | **0** | **90** |
| master (buggy *path* unreachable here) | 282/282/282/929 | 308/206/200/221 | 168 | 2 |
| ExportSnapshot | 0/0/0/0 | — | — | — |
| CopyTable | 0/0/0/647 | — | — | — |

The two rows are the same three runs, so the contrast is not an artifact: the **daemon
drifts hard** (308/206/200 distinct fails, noise floor 168) while the **client process is
exactly reproducible** (175 every time, noise 0). That is why the probe is the only place
detection is possible here -- and it is the opposite of the HDFS-16547 situation, where
daemon drift swallowed the signal entirely.

Only the probe row is usable. The master row carries a 3x round confound and the
copytable row is an artifact — both come from the fixed run taking longer, for the
reason in the next section.

## The 90 localize the bug

```
 12  OpProtectedBy  RestoreSnapshotHelper.restoreHdfsRegions -> Threads.setDaemonThreadRunning
  6  OpProtectedBy  RestoreSnapshotHelper.restoreHdfsRegions -> SnapshotDescriptionUtils.isExpiredSnapshot
  2  OpProtectedBy  RestoreSnapshotHelper.removeHdfsRegions  -> SnapshotDescriptionUtils.isExpiredSnapshot
  2  OpProtectedBy  RestoreSnapshotHelper.cloneHdfsRegions   -> SnapshotDescriptionUtils.isExpiredSnapshot
  2  OpProtectedBy  RestoreSnapshotHelper.getTableRegions    -> SnapshotDescriptionUtils.isExpiredSnapshot
  2  OpProtectedBy  RestoreMetaChanges.setNewRegions         -> SnapshotDescriptionUtils.isExpiredSnapshot
 24  OpProtectedBy  SnapshotManifest.{load,open,readDataManifest,...} -> Threads.getBoundedCachedThreadPool
  5  OpProtectedBy  SnapshotDescription.{hasTtl,hasCreationTime,...}  -> MasterProcedureEnv.getProcedureScheduler
```

**16 of the 90 name `SnapshotDescriptionUtils.isExpiredSnapshot` directly** — the exact
predicate the fix introduces. "`restoreHdfsRegions` is protected by `isExpiredSnapshot`"
states the missing guard: the restore work must not happen unless the expiry check ran
first. On the fixed build the exception is thrown before `SnapshotManifest.open()`, so the
protection relation completes; on the buggy build the work proceeds unguarded and it breaks.

Under `valuable-invariant-tiering.md` the `isExpiredSnapshot` group is **explicit** — it
names the fix's own predicate. This is a better result than the offline `check_trace`,
whose detections for this pair were mostly `Bytes.add` / `TableName.equals`
(weak-symbolic). The `Threads.*` pairs (60 of the class mentions) are thread-pool plumbing
on the manifest-loading path — weak-symbolic filler riding along with a proximate core.

## Two OKLib limitations this target exposed

Both follow from `RuntimeChecker`, and neither shows up on a daemon:

1. **The checker thread is non-daemon** (`RuntimeChecker.java:467`, `while (true)`), so an
   instrumented JVM never exits once `main` returns. HDFS-16547 and ZK-3531 instrumented
   daemons that get killed externally, so nobody noticed. Worse, it is **asymmetric
   between builds**: on the fixed build `CopyTable` throws `SnapshotTTLExpiredException`,
   which propagates out of `MainWrapper.invokeMainClass`, so `System.exit` is never
   reached and the JVM hangs forever — while the buggy build succeeds and exits cleanly.
   That asymmetry is the sole cause of the master/copytable round skew above.
2. **Short-lived JVMs get zero check rounds.** `checker.start()` runs `prepare()`
   (instrumenting ~7800 classes, minutes) and only then starts the thread, which sleeps
   **5 s** before its first round. Measured on `ExportSnapshot`: its work ran
   `05:17:37.440` → `05:17:39.440`, i.e. **2.0 s**, then `System.exit` — it died inside
   the warm-up. **0 rounds, 0 data**, likewise for `CopyTable`.

   This one is **a harness gap, not an OKLib defect**. A warm-up that skips startup noise
   is sound for a deployed checker, and a reproduction script's job is to trigger the bug,
   not to be a realistic workload — so it is legitimate for the harness to hold the JVM
   open. Wrapping `ExportSnapshot`/`CopyTable` the way `SnapshotProbe` is wrapped would
   give them rounds; that is simply not done here yet. Only item 1 is a genuine bug,
   because its effect differs between the two builds.

## Where this bug can actually be observed in a deployment

`copySnapshotForScanner` has four callers, all client- or MapReduce-side:
`TableSnapshotInputFormatImpl`, `MultiTableSnapshotInputFormatImpl`, `VerifyReplication`
(all hbase-mapreduce) and `TableSnapshotScanner`. Nothing in HMaster or HRegionServer
constructs any of them.

The methods are shared with the server — `restoreHdfsRegions()` is also called by
`RestoreSnapshotProcedure:393` and `CloneSnapshotProcedure:460` — but those master paths
are exactly the ones HBASE-27671 already guards, in **both** builds. So the *buggy path*,
not merely the buggy code, is client-only. That is why the master shows signal 2 against
noise 168, and why `PROBE_C` refuses on both sides.

In a real distributed cluster the call sits in `TableSnapshotInputFormatImpl.setInput()`,
which runs in the **MapReduce job driver** — a JVM that `bin/hbase` launches (so the patch
reaches it) but which lives for seconds. Not the master, not a region server, not a YARN
container.

**So there is no long-lived JVM in an HBase deployment where this bug executes.** Attached
the way HDFS-16547 and ZOOKEEPER-3531 were attached — daemons only — OKLib would see
nothing here. The 169 check rounds exist because a harness process we wrote holds itself
open for 180 s. The 90 invariants genuinely localize the fix, but they were observed in a
process that does not exist in a deployment, entered through two
`@InterfaceAudience.Private` classes.

Neither was fixed in `RuntimeChecker`: changing the checker mid-experiment would
invalidate comparison with the HDFS and ZK runs. Both are worked around in the harness
(`System.exit(0)` in `SnapshotProbe`, plus a `timeout` guard).

## Caveats

- **The noise floor is exactly 0 at n = 3.** All three buggy runs produced byte-identical
  probe fail sets (175, 169 rounds). Checked rather than assumed: the master JVM from the
  same three runs gives 308/206/200 and a floor of 168, so the runs are genuinely distinct
  and the probe's determinism is real — a client JVM with a fixed linger has none of a
  daemon's background chores. Still worth stating that a zero floor is a property of this
  workload's determinism, not a general guarantee.
- 3406 of 3799 invariants are **inactive** in the probe JVM. The donor was inferred inside
  one MiniCluster JVM where master-side and client-side events shared a stream; live they
  are separate processes. ~90% of the donor cannot fire where this bug executes.
- Cross-version donor: HBASE-27671 is 2.5.3-era (`620ab79b`), the target 2.5.10-SNAPSHOT.
- Raw logs: `oklib_runtime_logs/HBASE-28704/{buggyA,buggyB,fixed}/{master.out,probe.out,export.log,copytable.log}`.
  Scripts and method: `experiments/reproduce/HBASE-28704/`.
