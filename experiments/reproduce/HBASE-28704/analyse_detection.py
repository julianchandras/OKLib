#!/usr/bin/env python3
"""
Turn the three HBASE-28704 runs into a noise floor and a signal.

The question is never "which invariants failed on the buggy build" -- it is "which
failed on BOTH buggy runs and on NEITHER fixed run, and is that set bigger than the
disagreement between two runs of the SAME build". HDFS-16547 is the cautionary case:
15 apparently buggy-only invariants, noise floor 15, real signal 2.

Usage: analyse_detection.py [runs_dir]   (default oklib_runtime_logs/HBASE-28704)
"""
import re, sys, os
from pathlib import Path

BUGGY = ["buggyA", "buggyB", "buggyC"]   # any that exist; >2 tightens the noise floor
FIXED = "fixed"
RUNS = BUGGY + [FIXED]
# One file per JVM. The tool JVMs matter here because HBASE-28704 is client-side: the
# master is the one place the bug does NOT execute.
JVMS = {"master": "master.out", "probe": "probe.out",
        "export": "export.log", "copytable": "copytable.log"}

# Interleaved stdout can weld an id to a following timestamp (the ZK-3531 "#232026"
# artifact), so ids are bounded by the loaded-invariant count rather than trusted raw.
ID_RE = re.compile(r"ASSERT FAIL! #(\d+)")
LOADED_RE = re.compile(r"Total loaded invariants number: (\d+)")
ROUND_RE = re.compile(r"^Checking finished, succCount:(\d+) failCount: (\d+) inactiveCount: (\d+)", re.M)


def read(path):
    if not os.path.exists(path):
        return None
    txt = Path(path).read_text(errors="ignore")
    loaded = LOADED_RE.search(txt)
    loaded = int(loaded.group(1)) if loaded else None
    ids = {int(m) for m in ID_RE.findall(txt)}
    if loaded:
        bad = {i for i in ids if i >= loaded}
        ids = ids - bad
    else:
        bad = set()
    rounds = ROUND_RE.findall(txt)
    last = rounds[-1] if rounds else None
    return {"loaded": loaded, "ids": ids, "dropped": len(bad),
            "rounds": len(rounds), "last": last}


def main():
    base = Path(sys.argv[1] if len(sys.argv) > 1 else "oklib_runtime_logs/HBASE-28704")
    for jvm, fname in JVMS.items():
        data = {r: read(base / r / fname) for r in RUNS}
        if not any(data.values()):
            continue
        print(f"\n=== {jvm} ===")
        for r in RUNS:
            d = data[r]
            if d is None:
                print(f"  {r:8s} (no log)")
                continue
            last = f"pass={d['last'][0]} fail={d['last'][1]} inac={d['last'][2]}" if d['last'] else "no check round"
            drop = f" dropped={d['dropped']}" if d['dropped'] else ""
            print(f"  {r:8s} loaded={d['loaded']} distinct_fail_ids={len(d['ids'])} rounds={d['rounds']} [{last}]{drop}")

        buggy = [(r, data[r]) for r in BUGGY if data[r]]
        f = data[FIXED]
        if len(buggy) < 2 or not f:
            print("  -- incomplete; need >=2 buggy runs and the fixed run to judge")
            continue
        # Noise is the union of every same-build disagreement, not one pair: with n runs
        # any invariant that is not unanimous across them is drift, not signal.
        noise = set()
        for i in range(len(buggy)):
            for j in range(i + 1, len(buggy)):
                noise |= buggy[i][1]["ids"] ^ buggy[j][1]["ids"]
        common = set.intersection(*[d["ids"] for _, d in buggy])
        signal = common - f["ids"]
        reverse = f["ids"] - set.union(*[d["ids"] for _, d in buggy])
        names = "/".join(r for r, _ in buggy)
        print(f"  NOISE  (pairwise disagreement across {names}) = {len(noise)}")
        print(f"  SIGNAL (all {len(buggy)} buggy, not fixed)    = {len(signal)}")
        print(f"  reverse (fixed-only)                  = {len(reverse)}")
        if len(signal) > len(noise):
            print(f"  -> signal EXCEEDS noise floor; candidate ids: {sorted(signal)[:40]}")
        else:
            print("  -> signal within the noise floor; NOT a detection")
        # Round-count confound: a run with fewer rounds simply had fewer chances to fail.
        rounds = [data[r]["rounds"] for r in RUNS if data[r]]
        if min(rounds) and max(rounds) / max(min(rounds), 1) > 1.5:
            print(f"  [WARN] round counts differ a lot {dict(zip([r for r in RUNS if data[r]], rounds))};"
                  " check when the signal ids first fail before trusting this")


if __name__ == "__main__":
    main()
