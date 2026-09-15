# LISA benchmark on OKLib

Donor bug -> target bug: infer + verify invariants on the donor, then `check_trace` them
against the target's patched and unpatched traces.
**Detected** = passes on patched, fails on unpatched.

Run scripts from the repo root.

## Bug pairs

```
donor             target
SOLR-6931      -> SOLR-11881        # no test added in donor's patch
SOLR-11616     -> SOLR-13872
SOLR-8728      -> SOLR-9251
SOLR-9251      -> SOLR-9503

HDFS-13924     -> HDFS-16732
HDFS-1172      -> HDFS-9535
HDFS-14201     -> HDFS-16547
HDFS-9794      -> HDFS-9812         # no test added in donor's patch
HDFS-2484      -> HDFS-13816
HDFS-2484      -> HDFS-14529
HDFS-13816     -> HDFS-14529
HDFS-12931     -> HDFS-17897
HDFS-12931     -> HDFS-17899
HDFS-17897     -> HDFS-17899

HBASE-27671    -> HBASE-28704
HBASE-27580    -> HBASE-28482
HBASE-28226    -> HBASE-28241       # no test added in donor's patch
HBASE-28890    -> HBASE-28893
HBASE-13851    -> HBASE-15957       # no test added in donor's patch

ZOOKEEPER-2201 -> ZOOKEEPER-3531
ZOOKEEPER-1208 -> ZOOKEEPER-1496
ZOOKEEPER-122  -> ZOOKEEPER-268     # no test added in donor's patch
ZOOKEEPER-2380 -> ZOOKEEPER-2687
```

## Output directories

All at the repo root, all gitignored.

Written by the pipeline:

```
trace_output/<T>/          gentrace traces
inv_infer_output/<T>/      all_invs
inv_verify_output/<T>/     verified_invs  (whatever ran LAST)
inv_checktrace_output/     flat; <stem>_{p,up,detected,undetected}
```

Written by us:

```
inv_verify_archive/<T>/
    prefix/                before aliasing fix 70963be -> verify results void
    postfix/               after the fix -> use this
    master/                upstream OathKeeper (ZK-1208 only)
    INDEX.md               counts per ticket
inv_manual_scope/<T>/      filter script output + FILTER.meta run log
oklib_runtime_logs/<T>/    live runtime (prod mode) runs
backup/                    snapshots taken before a re-verify
```

- Each archive tier has `verified_invs` + `PROVENANCE` (build, jar md5, count).
- `backup/*_preverify_*` means *before the re-verify*, **not** pre-fix.
- The `check_trace` stem is free-form, so names there aren't consistent.

## Scripts

Keep invariants touching classes/fields you instrumented by hand
(`instrument_class_allmethods`, `instrument_state_fields`):

```sh
benchmark/scripts/filter_manual_scope.py HDFS-13924
benchmark/scripts/filter_manual_scope.py HDFS-13924 --strict     # every slot must match
benchmark/scripts/filter_manual_scope.py ZK-1496 --conf conf/samples/zk-1208.properties   # use donor's system config
```

Then narrow by keyword (one per line in `kw.txt`, matched against op/state names):

```sh
benchmark/scripts/filter_by_keywords.py HDFS-13924 kw.txt \
    --source inv_manual_scope/HDFS-13924/manual.verified_invs
```

- Default input: `inv_verify_archive/<T>/postfix/verified_invs`.
- Output keeps the exact `verified_invs` format (original text is copied, never
  re-serialised), so it can go straight back into `check_trace`.
- `oklib_invfilter.py` holds the shared helpers.
