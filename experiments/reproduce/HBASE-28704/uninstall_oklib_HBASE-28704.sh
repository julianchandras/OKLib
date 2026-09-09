#!/bin/bash
# Detach OKLib from a worktree -- the no-OKLib reproduction must be run clean.
# Usage: ./uninstall_oklib_HBASE-28704.sh [buggy|fixed|all]
side=${1:-all}
for s in $( [ "${side}" = "all" ] && echo "buggy fixed" || echo ${side} ); do
  wt=/localtmp/julian/hbase-28704-${s}
  [ -d "${wt}" ] && git -C ${wt} checkout -f -- bin/hbase && echo "detached ${s}"
done
