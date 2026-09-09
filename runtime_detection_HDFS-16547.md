# Live OKLib runtime detection — HDFS-16547

First end-to-end run of OKLib in **production mode inside real HDFS daemons**
(not `check_trace`, not MiniCluster). 2026-09-05.

## Setup

- Pseudo-distributed HA: two NameNode JVMs on one host, 0 datanodes, 0 ZKFC, 0 journalnodes
- Buggy build `dc2fba45fef`; fixed build `8f971b0e541` (adds the safemode guard to
  `NameNode.transitionToObserver`)
- OKLib attached via `install_hdfs.patch` → `hadoop_start_daemon` → `MainWrapper`
- 192 invariants loaded from `inv_prod_input`: HDFS-13924 (108) + HDFS-14201 (84)
- Trigger: both NNs to safe mode, then `haadmin -transitionToObserver nn1`

## Reproduction: works

| build | exit | nn1 final state |
|---|---|---|
| buggy | 0 | **observer**, safe mode still ON |
| fixed | 255 | standby, `still not leave safemode` |

## OKLib attaches and runs

`Total loaded invariants number: 192`, then a check every ~2 s — 144 rounds in a
~90 s run, event queue growing 1197 → 2031. Each daemon checks independently and
writes `ASSERT FAIL! #<id>` to its own `HADOOP_LOG_DIR/*.out`. Instrumentation
noise: 2650 `javassist.CannotCompileException`, 43 `NotFoundException`,
comparable to historical gentrace logs; not fatal.

## Detection: NO

Distinct invariant IDs that failed at least once, nn1:

| run | failing invariants |
|---|---|
| buggy run 1 | 89 |
| buggy run 2 | 74 |
| fixed | 74 |

| comparison | invariants differing |
|---|---|
| **buggy run1 vs buggy run2 — same build, pure noise** | **15** |
| buggy run1 vs fixed | 15 |
| buggy run2 vs fixed | 2 |

The between-build difference is **inside the within-build variance**. Worse, the
15 invariants separating buggy-run1 from fixed are nearly the identical set that
separates buggy-run1 from buggy-run2 (they differ only in #107 vs #109) — run 1
was simply a noisy run. nn2 is the same story: noise 33, signal 9.

Had we run only buggy-run1 against fixed, 15 invariants would have looked like a
detection. **A same-build control run is mandatory for this experiment.**

## Localization: impossible by construction

Of the 192 loaded invariants, exactly **one** mentions safe mode
(`BlockManagerSafeMode.isInSafeMode()`, block-report safemode — not the HA
`notBecomeActiveInSafemode` guard). **Zero** mention observer, `HAState`, or
`transitionTo*`.

The instrumentation config does track the right state
(`notBecomeActiveInSafemode`, `manualSafeMode`, `resourceLowSafeMode`,
`state.getServiceState().ordinal()`), but no loaded invariant refers to any of
it, so no violation of this bug's property can be expressed.

The buggy-only invariants are all RPC/timing plumbing —
`RpcWritable$ProtobufWrapper.readFrom`, `UserGroupInformation.hashCode`,
`Time.now`, `FSNamesystem.isRunning`. Noise by the proximate-relatedness test.

## Caveats

1. Donor invariants come from HDFS-14201's **1 May verify, which predates the
   `70963be` aliasing fix** and is void (99.5% `pass == 0`). A post-fix
   re-verify may yield a materially different set.
2. 41 of the 84 reference `PendingReconstructionBlocks`; we ran 0 datanodes, so
   they can never fire here.
3. n = 3 runs. The noise band is estimated, not tightly bounded.
4. Nothing was tuned toward this bug — no invariant was inferred from a trace
   that exercises `transitionToObserver` in safe mode.

## What would change the verdict

- Re-verify HDFS-14201 post-fix and restage (~2 h; backup already at
  `backup/HDFS-14201_preverify_20260905/`)
- Use a donor whose invariants actually cover the safemode/HA-state transition
- More repetitions to bound the noise properly
