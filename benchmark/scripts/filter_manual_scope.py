#!/usr/bin/env python3
"""
Keep only the invariants that touch something we instrumented on purpose.

A post-fix donor set is mostly classes that relaxed-selective pulled in by closure, not
classes anyone chose: HDFS-13924 names 7 classes in its config and 124 turn up in the
result. This filters back down to the chosen ones, so the set is small enough to read.

  benchmark/scripts/filter_manual_scope.py HDFS-13924
  benchmark/scripts/filter_manual_scope.py HDFS-13924 --strict
  benchmark/scripts/filter_manual_scope.py ZK-1208 --conf conf/samples/zk-cc.properties
  benchmark/scripts/filter_manual_scope.py HBASE-27671 --extra-class org.apache.hadoop.hbase.io.HFileLink

Output: inv_manual_scope/<TICKET>/manual[_strict].verified_invs, in the original format.
"""

import argparse
import collections

import oklib_invfilter as ok


def build_parser():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("ticket", help="bug id, e.g. HDFS-13924")
    p.add_argument("--strict", action="store_true",
                   help="require EVERY slot to be manually instrumented (default: at least one)")
    p.add_argument("--conf", help="system .properties; needed when it isn't conf/samples/<ticket>.properties")
    p.add_argument("--source", help="verified_invs to read (default: archived post-fix copy)")
    p.add_argument("--extra-class", action="append", default=[], metavar="FQCN",
                   help="treat this class as manually instrumented (repeatable)")
    p.add_argument("--extra-field", action="append", default=[], metavar="FQCN.field",
                   help="treat this state field as manually instrumented (repeatable)")
    p.add_argument("-o", "--out", help="override the output path")
    return p


def main():
    args = build_parser().parse_args()
    ticket = args.ticket.upper()

    src = ok.resolve_source(ticket, args.source)
    conf = ok.resolve_conf(ticket, args.conf)
    classes, fields = ok.manual_targets(ok.parse_properties(conf))
    classes |= set(args.extra_class)
    fields |= set(args.extra_field)

    if not classes and not fields:
        raise SystemExit(
            f"{conf} lists no instrument_class_allmethods and no instrument_state_fields.\n"
            "Nothing was instrumented by hand, so there is nothing to filter to."
        )

    text, spans, invs = ok.load_invariants(src)

    def slot_is_manual(kind, name):
        # Ops: the class must be in instrument_class_allmethods.
        #
        # States: two ways in. Either the field is listed in instrument_state_fields, or
        # it is a Map/List field that DynamicClassModifier.appendTrackedStates() picked up
        # automatically (tracked as .size()). That auto-scan walks every class in
        # opInstClasses, which includes whole packages pulled in by the git-diff expansion
        # and relaxed-selective usage analysis -- not just our list. So an auto field only
        # counts as "ours" when its owning class is one we actually named in allmethods.
        if kind == "op":
            return ok.owner_class(name) in classes
        return name in fields or ok.owner_class(name) in classes

    keep, hits = [], collections.Counter()
    for idx, inv in enumerate(invs):
        slots = list(ok.iter_slots(inv))
        if not slots:
            continue
        flags = [slot_is_manual(kind, name) for _, kind, name in slots]
        if (all(flags) if args.strict else any(flags)):
            keep.append(idx)
            for (_, _, name), ok_flag in zip(slots, flags):
                if ok_flag:
                    hits[ok.owner_class(name)] += 1

    name = args.out or (ok.out_dir(ticket) / f"manual{'_strict' if args.strict else ''}.verified_invs")
    ok.write_subset(name, text, spans, keep)

    sigs = {ok.signature(invs[i]) for i in keep}
    mode = "ALL slots manual" if args.strict else "at least one slot manual"
    print(f"{ticket}  [{mode}]")
    print(f"  source     : {src}")
    print(f"  build      : {ok.source_build(src)}")
    print(f"  config     : {conf}")
    print(f"  manual set : {len(classes)} classes, {len(fields)} state fields")
    print(f"  invariants : {len(invs)} -> {len(keep)}"
          f"  ({100.0 * len(keep) / len(invs):.1f}%)" if invs else "  invariants : 0")
    print(f"  distinct signatures : {len(sigs)}")
    if hits:
        print("  carried by :")
        for cls, n in hits.most_common():
            print(f"      {n:6d}  {cls}")
    print(f"  written    : {name}")

    ok.log_meta(ticket, [
        f"script      : filter_manual_scope.py ({mode})",
        f"source      : {src}",
        f"source build: {ok.source_build(src)}",
        f"config      : {conf}",
        f"classes     : {sorted(classes)}",
        f"state fields: {sorted(fields)}",
        f"counts      : {len(invs)} -> {len(keep)} ({len(sigs)} distinct signatures)",
        f"output      : {name}",
    ])


if __name__ == "__main__":
    main()
