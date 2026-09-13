#!/usr/bin/env python3
"""
Narrow an invariant set to the ones mentioning anything in a keyword file.

Second-stage filter: run filter_manual_scope.py first, then point this at its output to
zoom in on whatever you are actually reading about (a method, a field, a subsystem).

Keywords are matched as substrings against opName/stateName ONLY -- not against the raw
JSON -- so a numeric or short keyword can't accidentally hit a timestamp or a stats block.

  benchmark/scripts/filter_by_keywords.py HDFS-13924 kw.txt
  benchmark/scripts/filter_by_keywords.py HDFS-13924 kw.txt --source inv_manual_scope/HDFS-13924/manual.verified_invs
  benchmark/scripts/filter_by_keywords.py HDFS-13924 kw.txt --all      # invariant must match every keyword

kw.txt is one entry per line; blank lines and #-comments ignored. Example:
    getBlockLocations
    LocatedBlock.locs
    # a whole class works too
    org.apache.hadoop.hdfs.server.namenode.FSNamesystem

Output: inv_manual_scope/<TICKET>/kw_<stem>.verified_invs, in the original format.
"""

import argparse
import collections
from pathlib import Path

import oklib_invfilter as ok


def read_keywords(path):
    out = []
    for raw in Path(path).read_text().splitlines():
        line = raw.strip()
        if line and not line.startswith("#"):
            out.append(line)
    if not out:
        raise SystemExit(f"{path} has no usable entries (all blank or commented)")
    return out


def build_parser():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("ticket", help="bug id, e.g. HDFS-13924")
    p.add_argument("keywords", help="file with one keyword per line")
    p.add_argument("--source", help="verified_invs to read (default: archived post-fix copy)")
    p.add_argument("--all", action="store_true",
                   help="require EVERY keyword to match somewhere in the invariant (default: any)")
    p.add_argument("-o", "--out", help="override the output path")
    return p


def main():
    args = build_parser().parse_args()
    ticket = args.ticket.upper()

    src = ok.resolve_source(ticket, args.source)
    keywords = read_keywords(args.keywords)
    text, spans, invs = ok.load_invariants(src)

    keep, hits = [], collections.Counter()
    for idx, inv in enumerate(invs):
        names = [name for _, _, name in ok.iter_slots(inv)]
        if not names:
            continue
        matched = {kw for kw in keywords if any(kw in n for n in names)}
        if (len(matched) == len(keywords)) if args.all else bool(matched):
            keep.append(idx)
            hits.update(matched)

    stem = Path(args.keywords).stem
    name = args.out or (ok.out_dir(ticket) / f"kw_{stem}.verified_invs")
    ok.write_subset(name, text, spans, keep)

    sigs = {ok.signature(invs[i]) for i in keep}
    mode = "ALL keywords" if args.all else "any keyword"
    print(f"{ticket}  [{mode}]")
    print(f"  source     : {src}")
    print(f"  build      : {ok.source_build(src)}")
    print(f"  keywords   : {len(keywords)} from {args.keywords}")
    print(f"  invariants : {len(invs)} -> {len(keep)}")
    print(f"  distinct signatures : {len(sigs)}")
    print("  per keyword:")
    for kw in keywords:
        n = hits.get(kw, 0)
        print(f"      {n:6d}  {kw}" + ("   <- matched nothing" if n == 0 else ""))
    print(f"  written    : {name}")

    ok.log_meta(ticket, [
        f"script      : filter_by_keywords.py ({mode})",
        f"source      : {src}",
        f"source build: {ok.source_build(src)}",
        f"keyword file: {args.keywords} ({len(keywords)} entries)",
        f"counts      : {len(invs)} -> {len(keep)} ({len(sigs)} distinct signatures)",
        f"unmatched   : {[k for k in keywords if hits.get(k, 0) == 0]}",
        f"output      : {name}",
    ])


if __name__ == "__main__":
    main()
