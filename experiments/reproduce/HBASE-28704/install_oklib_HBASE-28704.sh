#!/bin/bash
# Attach OKLib to a built HBASE-28704 worktree, in production (runtime-checking) mode.
#
# Two JVMs matter here, and they need different treatment:
#
#   the daemon  -- HMaster (which in standalone also hosts the RegionServer) is launched
#                  through bin/hbase, so it needs the patch: MainWrapper cannot be
#                  injected through HBASE_OPTS, it has to become the main class.
#   the tools   -- ExportSnapshot and CopyTable also go through bin/hbase, so they
#                  pick up the same patch. They get their own ok roots via the
#                  OK_ROOT_OVERRIDE env var the patch honours; without it all three
#                  would share the master's inv_prod_input, oklogs and ok.prod.log.
#   the probe   -- HBASE-28704 lives in a short-lived CLIENT process, not a daemon. That
#                  JVM is launched by trigger_HBASE-28704.sh directly, which passes the
#                  same -Dok.* flags on its own command line (the ZK-3531 idiom), so
#                  nothing here has to cover it.
#
# Usage: ./install_oklib_HBASE-28704.sh [OathKeeper folder] [buggy|fixed] [worktree]

if [ $# -lt 2 ]; then
    echo "Usage: $0 [OathKeeper folder] [buggy|fixed] [worktree]"
    exit 1
fi
set -e
ok_dir=$1
side=$2
sys_dir=${3:-/localtmp/julian/hbase-28704-${side}}
DATA=/localtmp/julian/hbase-28704-data/${side}
# Deliberately NOT under ${DATA}: the trigger begins with `rm -rf ${DATA}`, which would
# delete the staged invariants and the prod conf between attach and run.
OKDATA=/localtmp/julian/hbase-28704-oklib/${side}
HERE=${ok_dir}/experiments/reproduce/HBASE-28704
DONOR=HBASE-27671

jar=${ok_dir}/target/OathKeeper-1.0-SNAPSHOT-jar-with-dependencies.jar
if [ ! -f "${jar}" ]; then
  echo "[ERROR] ok_lib jar missing. Run: mvn clean package -DskipTests"
  exit 1
fi
# The pipeline never rebuilds ok_lib, and a stale jar has silently produced bad runs
# before (lift12's was 12 days old, missing the EventTracer aliasing fix). Say how old.
echo "ok_lib jar: $(date -r ${jar} '+%Y-%m-%d %H:%M')  (HEAD $(git -C ${ok_dir} log -1 --format='%h %cd' --date=short))"

test -d "${sys_dir}" || { echo "[ERROR] no worktree at ${sys_dir}"; exit 1; }
rm -rf ${OKDATA}
mkdir -p ${OKDATA}

# --- per-JVM ok roots -------------------------------------------------------------
# One per JVM. Sharing means sharing inv_prod_input, oklogs and ok.prod.log; on the
# HDFS-16547 run that collision truncated the prod log to 0 bytes.
for role in master probe export copytable; do
  okroot=${OKDATA}/ok-${role}
  mkdir -p ${okroot}/inv_prod_input/${DONOR}
  cp ${ok_dir}/inv_verify_output/${DONOR}/verified_invs ${okroot}/inv_prod_input/${DONOR}/
done

# --- prod conf, one per side (system_dir_path differs) ------------------------------
conf_file=${OKDATA}/oklib-prod.properties
sed -e "s|SYS_DIR_MACRO|${sys_dir}|g" \
    ${ok_dir}/conf/samples/hbase-28704-prod.properties.template > ${conf_file}

# --- patch bin/hbase ----------------------------------------------------------------
cd ${sys_dir}
git checkout -f -- bin/hbase
sed -e "s|OK_DIR_MACRO|${ok_dir}|g" \
    -e "s|OK_ROOT_MACRO|${OKDATA}/ok-master|g" \
    -e "s|CONF_PATH_MACRO|${conf_file}|g" \
    -e "s|SYS_DIR_MACRO|${sys_dir}|g" \
    ${ok_dir}/conf/samples/hb-patches/install_hbase.patch > ${OKDATA}/install_hbase.patch
git apply ${OKDATA}/install_hbase.patch

echo
echo "=== bin/hbase launch line is now ==="
grep -n "MainWrapper\|^OKFLAGS=\|^CLASSPATH=" ${sys_dir}/bin/hbase

echo
echo "=== invariants staged for each JVM ==="
for role in master probe export copytable; do
  f=${OKDATA}/ok-${role}/inv_prod_input/${DONOR}/verified_invs
  echo "  ${role}: $(grep -c '"template"' ${f}) invariants from ${DONOR}"
done
echo
echo "Donor re-verified 2026-09-05 post-70963be (29448s). 147 -> 3799 invariants."
echo "Tests with an empty pass list fell 49.3% -> 7.7%, so the old set was materially"
echo "degraded by the aliasing bug, not merely suspect. Pre-fix copy kept at"
echo "backup/HBASE-27671_preverify_20260905/."
