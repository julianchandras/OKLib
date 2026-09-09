#!/bin/bash
# The runtime detection experiment for HBASE-28704: buggy x2 + fixed x1.
#
# The repeat is not optional. HDFS-16547 showed 15 apparently buggy-only invariants
# collapse to a noise floor of 15 and a real signal of 2 once a same-build control
# existed. Without buggy-vs-buggy there is no way to tell signal from run-to-run drift.
#
# Usage: ./run_detection_HBASE-28704.sh [OathKeeper folder]
set -e
ok_dir=${1:-/localtmp/julian/OKLib}
HERE=${ok_dir}/experiments/reproduce/HBASE-28704
# Run from a copy: bash reads scripts incrementally, so editing the trigger mid-run
# breaks the running shell.
SNAP=$(mktemp -d)
cp ${HERE}/trigger_HBASE-28704.sh ${SNAP}/trigger.sh
chmod +x ${SNAP}/trigger.sh

run_one () {   # $1 = side, $2 = tag
  local side=$1 tag=$2
  echo "############ ${tag} (${side}) $(date '+%F %T') ############"
  ${HERE}/cleanup_HBASE-28704.sh ${side} >/dev/null 2>&1 || true
  ${HERE}/install_oklib_HBASE-28704.sh ${ok_dir} ${side} > ${ok_dir}/hbase28704_attach_${tag}.log 2>&1
  WITH_OKLIB=1 ${SNAP}/trigger.sh ${ok_dir} ${side} > ${ok_dir}/hbase28704_oklib_${tag}.log 2>&1 || true
  ${HERE}/cleanup_HBASE-28704.sh ${side} >/dev/null 2>&1 || true
  # ok roots live outside ${DATA}, but ${DATA} itself is wiped by the next trigger run,
  # so the per-JVM logs have to be preserved now.
  local out=${ok_dir}/oklib_runtime_logs/HBASE-28704/${tag}
  mkdir -p ${out}
  local D=/localtmp/julian/hbase-28704-data/${side}
  for f in probe.out setup.out export.log copytable.log; do
    [ -f ${D}/${f} ] && cp ${D}/${f} ${out}/ || true
  done
  cp ${D}/log/*master*.out ${out}/master.out 2>/dev/null || true
  echo "   -> ${out}"
}

run_one buggy buggyA
run_one buggy buggyB
run_one fixed fixed
echo "############ DETECTION RUNS DONE $(date '+%F %T') ############"
