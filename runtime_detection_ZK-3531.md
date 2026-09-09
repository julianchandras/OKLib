# Live OKLib runtime detection — ZOOKEEPER-3531

OKLib in production mode inside a real 3-node ZooKeeper ensemble. 2026-09-05.
Companion to `runtime_detection_HDFS-16547.md`, which was a null result.

**Verdict: DETECTED, and localized to the bug's own code path.**

## Setup

- Pseudo-distributed: 3 `QuorumPeerMain` JVMs on one host, ports 2181-3 / 2888-90 / 3888-90
- Buggy `2dcb5e799`; fixed `f4c7b698b` (makes `ReferenceCountedACLCache.serialize`
  clone the map under a short lock and write outside it)
- Donor: **ZK-2201, re-verified post-`70963be`** -- 143 invariants over
  `StatPersisted` (163 refs), `DataTree` (93), `DataNode` (30)
- OKLib attached per JVM (jar + `-Dok.*` + `MainWrapper`) directly in the launch
  command, so no edit to `install_zk-3.6.1.patch`, and **each server gets its own
  `ok.ok_root_abs_path`** -- avoiding the shared `ok.prod.log` collision that
  truncated the HDFS run's log to 0 bytes.

## Fault injection

`LearnerHandler:580 -> serializeSnapshot -> DataTree.serialize -> serializeAcls ->
aclCache.serialize -> oa.writeInt`, blocking on the socket to a stalled learner.

Load 30k znodes with 4KB distinct ACL ids (the ACL section is written *first* and
the monitor is released before the nodes, so the ACL data alone must exceed the
socket buffer), kill a follower, write past the committed-log window, restart it,
and `SIGSTOP` it the instant the leader logs `Sending snapshot`. No root, no iptables.

## Reproduction is differential

| build | probe | leader jstack |
|---|---|---|
| buggy | `HUNG_CONNECTION_LOSS` (x2) | `LearnerHandler` in `socketWrite0` inside `serialize`, **`- locked <0x700e85a28> (ReferenceCountedACLCache)`**; `ProcessThread` **BLOCKED** `waiting to lock <0x700e85a28>` |
| fixed | `COMPLETED` | same blocking call, but `- locked` covers only the stream objects; **0** threads blocked on the monitor |

Same injection, same stall point, no hang -- so the hang is the bug, not the method.

## Detection

Distinct failing invariant IDs (filtered to the valid range 0-142; see caveats):

| run | zk1 (follower) | zk3 (leader) |
|---|---|---|
| buggyA | 102 | 107 |
| buggyB | 101 | 105 |
| fixed  |  86 | 109 |

| comparison | zk1 | zk3 |
|---|---|---|
| **noise** (buggyA vs buggyB, same build) | **1** | 8 |
| **consistent buggy-only** (fail in both buggy, neither fixed) | **15** | 1 |
| consistent fixed-only | **0** | 8 |

On the follower the signal is 15 against a noise floor of 1, one-directional.
On the leader signal < noise: nothing.

**Round-count confound ruled out.** The fixed run ran 31 check rounds vs the buggy
runs' 85-86, so fewer chances to fail. All 15 first fail in rounds **2-19** in both
buggy runs -- well inside 31.

## The 15 invariants localize the bug

```
#28,32,34,36,37,38,41,42,44,45  OpImplyOp    DataTree.serialize     => StatPersisted.get*/set*
#63                             OpImplyOp    DataTree.serializeNode => StatPersisted.getAversion
#6,9,18                         OpHappenBefore StatPersisted.set*   -> DataNode.serialize
#7                              OpHappenBefore StatPersisted.setEphemeralOwner -> StatPersisted.serialize
```

`DataTree.serialize => StatPersisted.getCzxid` means "if serialization starts, the
per-node field reads follow". The leader stalls inside `serializeAcls` holding the
ACL monitor, so serialization never reaches the nodes and the implication breaks.
That is the bug's mechanism. Compare HDFS-16547, where the candidate detections were
RPC header parsing and `UserGroupInformation.hashCode` -- noise.

## Two findings

1. **The detection is on the follower, not the leader.** A hung process stops
   emitting events, so its invariants go INACTIVE rather than FAIL. The live peer
   observes the consequence. A runtime checker can catch a hang, but not from
   inside the hung process.
2. **Re-verifying the donor is what made this work.** These 15 come from the
   143-invariant post-fix ZK-2201 set. The pre-fix set was 33 invariants with 85%
   `pass == 0`; HDFS-16547 with its equivalent void set detected nothing.

## Caveats

- n = 2 buggy runs; the noise floor is estimated, not bounded.
- Interleaved stdout corrupts some `ASSERT FAIL` lines (`#23` merged with a
  following timestamp into `#232026`). IDs were filtered to 0-142. Worth fixing at
  the source before publishing these numbers.
- The old ZK-2201 verify output is not a valid comparator for the new one: its
  `inv.id` holds 692 records across 7 packages from an unlogged later run, while
  the logged run registered 22 classes in one package. Only the new numbers are used here.
- Raw logs: `oklib_runtime_logs/ZK-3531/{buggyA,buggyB,fixed}/zk{1,2,3}.out`,
  plus `leader-jstack.txt` and the no-OKLib reproduction logs.
