#!/bin/bash
# Live reproduction of HBASE-28704:
#   a snapshot whose TTL has expired can still be read.
#
# Standalone HBase (master + regionserver + ZK in one JVM, rootdir on the local FS).
#
# The JIRA's headline triggers -- CopyTable and ExportSnapshot -- are MapReduce jobs.
# The third path the fix guards, RestoreSnapshotHelper.copySnapshotForScanner, is
# reachable from a plain client through TableSnapshotScanner, so that is what the probe
# drives. ExportSnapshot is then run as a second, tool-level confirmation.
#
# NOTE: Admin.restoreSnapshot / Admin.cloneSnapshot are NOT triggers for this bug --
# HBASE-27671 (the donor of this pair) already guards those, and 27671 is in both
# builds. The probe asserts that as a control.
#
# Usage: ./trigger_HBASE-28704.sh [OathKeeper folder] [buggy|fixed] [hbase worktree]

if [ $# -lt 2 ]; then
    echo "Usage: $0 [OathKeeper folder] [buggy|fixed] [hbase worktree]"
    exit 1
fi
set -e
ok_dir=$1
side=$2
sys_dir=${3:-/localtmp/julian/hbase-28704-${side}}
HERE=${ok_dir}/experiments/reproduce/HBASE-28704
DATA=/localtmp/julian/hbase-28704-data/${side}
OKDATA=/localtmp/julian/hbase-28704-oklib/${side}
export JAVA_HOME=${JAVA_HOME:-/usr/lib/jvm/java-8-openjdk-amd64}
export PATH=${JAVA_HOME}/bin:${PATH}

TTL=${TTL:-20}
ROWS=${ROWS:-2000}
LINGER=${LINGER:-}
TABLE=t28704
SNAPSHOT=t28704-snap
CLONE=t28704clone
COPYDEST=t28704copy
# Ports are per side, not shared. The trigger deliberately leaves its cluster up for
# inspection, so running the other side next would otherwise collide -- HBase refuses to
# start if MiniZooKeeperCluster cannot get the exact requested port ("Could not start ZK
# at requested port of 2191. ZK was started at port: 2192. Aborting").
case ${side} in
  buggy) ZKPORT=${ZKPORT:-2191}; MASTERPORT=${MASTERPORT:-16100}; RSPORT=${RSPORT:-16120} ;;
  fixed) ZKPORT=${ZKPORT:-2193}; MASTERPORT=${MASTERPORT:-16130}; RSPORT=${RSPORT:-16140} ;;
  *) echo "[ERROR] side must be buggy or fixed, got '${side}'"; exit 1 ;;
esac
for port in ${ZKPORT} ${MASTERPORT} ${RSPORT}; do
  if (ss -lnt 2>/dev/null || netstat -lnt) | grep -q ":${port} "; then
    echo "[ERROR] port ${port} already in use; stop the other cluster first"
    exit 1
  fi
done

test -d "${sys_dir}" || { echo "[ERROR] no worktree at ${sys_dir} -- run install_HBASE-28704.sh"; exit 1; }
test -f "${sys_dir}/hbase-build-configuration/target/cached_classpath.txt" \
  || { echo "[ERROR] ${sys_dir} is not built (no cached_classpath.txt)"; exit 1; }

CONF=${DATA}/conf
export HBASE_CONF_DIR=${CONF}
export HBASE_LOG_DIR=${DATA}/log
export HBASE_PID_DIR=${DATA}/pid
export HBASE_IDENT_STRING=hb28704-${side}
HBASE=${sys_dir}/bin/hbase

stop_cluster () {
  if [ -d "${CONF}" ]; then
    ${sys_dir}/bin/hbase-daemon.sh --config ${CONF} stop master >/dev/null 2>&1 || true
  fi
  for p in $(cat ${HBASE_PID_DIR}/*.pid 2>/dev/null); do kill -9 $p 2>/dev/null || true; done
}

echo "=== clean state (${side}) ==="
stop_cluster
rm -rf ${DATA}
mkdir -p ${CONF} ${HBASE_LOG_DIR} ${HBASE_PID_DIR} ${DATA}/hbase ${DATA}/tmp ${DATA}/zk ${DATA}/restore

cp -a ${sys_dir}/conf/. ${CONF}/
sed -e "s|ROOTDIR|${DATA}/hbase|" -e "s|TMPDIR|${DATA}/tmp|" -e "s|ZKDIR|${DATA}/zk|" \
    -e "s|ZKPORT|${ZKPORT}|" -e "s|MASTERPORT|${MASTERPORT}|" -e "s|RSPORT|${RSPORT}|" \
    ${HERE}/hbase-site.xml.template > ${CONF}/hbase-site.xml
{ echo "export JAVA_HOME=${JAVA_HOME}"
  echo "export HBASE_MANAGES_ZK=true"
  echo "export HBASE_LOG_DIR=${HBASE_LOG_DIR}"
  echo "export HBASE_PID_DIR=${HBASE_PID_DIR}"
  echo "export HBASE_IDENT_STRING=${HBASE_IDENT_STRING}"
  # WITH_OKLIB is threaded through hbase-env.sh because bin/hbase-daemon.sh re-execs
  # bin/hbase in a fresh shell; plain `export` from here would not survive nohup+su.
  [ -n "${HBASE_OPTS_EXTRA}" ] && echo "export HBASE_OPTS=\"\${HBASE_OPTS} ${HBASE_OPTS_EXTRA}\""
} >> ${CONF}/hbase-env.sh

echo "=== compile probes against ${side} classpath ==="
CP=$(${HBASE} --config ${CONF} classpath 2>/dev/null | tail -1)
CLASSES=${DATA}/probe-classes
mkdir -p ${CLASSES}
javac -nowarn -cp "${CP}" -d ${CLASSES} ${HERE}/SnapshotSetup.java ${HERE}/SnapshotProbe.java

echo "=== start standalone HBase (${side}) ==="
${sys_dir}/bin/hbase-daemon.sh --config ${CONF} start master

echo "=== wait for master ==="
up=no
for i in $(seq 1 120); do
  # The daemon script returns as soon as the JVM forks, long before the master is
  # usable; wait for the master's own "completed initialization" line instead.
  if grep -q "Master has completed initialization" ${HBASE_LOG_DIR}/*master*.log 2>/dev/null; then
    up=yes; break
  fi
  sleep 2
done
if [ "${up}" != "yes" ]; then
  echo "[ERROR] master never finished initialising"
  tail -40 ${HBASE_LOG_DIR}/*master*.log 2>/dev/null
  exit 1
fi
echo "  master up"

echo
echo "=== create table, load ${ROWS} rows, snapshot with TTL=${TTL}s ==="
# Each JVM writes to its own file. Sharing the script's stdout means the shell and a
# java process write through the same fd at different offsets and shred each other's
# lines -- the ZK-3531 run hit this and lost ASSERT FAIL ids to it.
java -cp "${CLASSES}:${CP}" SnapshotSetup ${TABLE} ${SNAPSHOT} ${TTL} ${ROWS} ${COPYDEST} \
  > ${DATA}/setup.out 2>&1
grep -E "^SETUP_" ${DATA}/setup.out
grep -q "^SETUP_RESULT=OK" ${DATA}/setup.out || { echo "[ERROR] setup failed"; tail -20 ${DATA}/setup.out; exit 1; }

echo
echo "=== wait out the TTL (${TTL}s + 5s slack) ==="
sleep $((TTL + 5))

echo
echo "=== PROBE: read the expired snapshot ==="
# WITH_OKLIB=1 attaches OathKeeper to the probe JVM the same way trigger_ZK-3531.sh does
# it -- jar first on the classpath, -Dok.* flags, MainWrapper ahead of the real main
# class -- with its OWN ok root, separate from the master's.
# This is the JVM that matters for HBASE-28704: the bug is in client-side snapshot
# reading, not in a daemon. A daemon gets checked for as long as it runs; this process
# lives seconds, so LINGER holds it open long enough for check rounds to close.
probe_pre=""
probe_okflags=""
probe_main=""
if [ "${WITH_OKLIB:-0}" = "1" ]; then
  OK_JAR=${ok_dir}/target/OathKeeper-1.0-SNAPSHOT-jar-with-dependencies.jar
  test -f "${OK_JAR}" || { echo "[ERROR] ok_lib jar missing"; exit 1; }
  probe_pre="${OK_JAR}:"
  test -f "${OKDATA}/oklib-prod.properties" || { echo "[ERROR] run install_oklib_HBASE-28704.sh first"; exit 1; }
  probe_okflags="-Dok.invmode=prod -Dok.conf=${OKDATA}/oklib-prod.properties \
                 -Dok.ok_root_abs_path=${OKDATA}/ok-probe -Dok.target_system_abs_path=${sys_dir}"
  probe_main="oathkeeper.engine.MainWrapper"
  # default only; ${LINGER:-60} would not fire here because LINGER is set-but-empty
  [ -z "${LINGER}" ] && LINGER=180
fi
[ -z "${LINGER}" ] && LINGER=0
set +e
# Belt and braces: SnapshotProbe now calls System.exit(0), but if it ever dies before
# that, OKLib's non-daemon RuntimeChecker would hold the JVM open forever and block this
# script. The verdict is read from probe.out, not from the exit code, so a timeout kill
# costs nothing.
timeout --signal=TERM --kill-after=30 $((LINGER + 900)) \
  java -cp "${probe_pre}${CLASSES}:${CP}" ${probe_okflags} ${probe_main} \
  SnapshotProbe ${SNAPSHOT} file://${DATA}/restore ${CLONE} ${LINGER} > ${DATA}/probe.out 2>&1
probe_rc=$?
[ ${probe_rc} -eq 124 ] && echo "  [WARN] probe JVM hit the timeout and was killed"
grep -E "^PROBE_" ${DATA}/probe.out
set -e

echo
echo "=== ExportSnapshot: the tool-level path from the JIRA description ==="
set +e
rm -rf ${DATA}/export
OK_ROOT_OVERRIDE=${OKDATA}/ok-export \
${HBASE} --config ${CONF} org.apache.hadoop.hbase.snapshot.ExportSnapshot \
  --snapshot ${SNAPSHOT} --copy-to file://${DATA}/export --no-checksum-verify \
  > ${DATA}/export.log 2>&1
export_rc=$?
set -e
echo "  ExportSnapshot exit code: ${export_rc}"
grep -m2 "SnapshotTTLExpiredException\|Export Completed\|Snapshot export failed" ${DATA}/export.log | sed 's/^/    /' || true

echo
echo "=== CopyTable --snapshot: the variant with the strongest offline signal ==="
# Same production change as PROBE_A (TableSnapshotInputFormat calls
# copySnapshotForScanner), but wrapped in a MapReduce job. Offline this variant
# yielded 27 detected invariants against RestoreSnapshot's 9 -- the extra events come
# from the job, not from a different bug site. LocalJobRunner, no YARN.
set +e
OK_ROOT_OVERRIDE=${OKDATA}/ok-copytable \
${HBASE} --config ${CONF} org.apache.hadoop.hbase.mapreduce.CopyTable \
  --snapshot --new.name=${COPYDEST} --bulkload ${SNAPSHOT} > ${DATA}/copytable.log 2>&1
copy_rc=$?
set -e
echo "  CopyTable exit code: ${copy_rc}"
grep -moE "SnapshotTTLExpiredException|Job .* completed successfully" ${DATA}/copytable.log | head -2 | sed 's/^/    /' || true

echo
echo "-------------------------------------------------------------"
echo "side=${side}  probe_exit=${probe_rc}  export_exit=${export_rc}  copy_exit=${copy_rc}"
echo
echo "REPRODUCED (buggy) if  PROBE_A=READ_EXPIRED_SNAPSHOT"
echo "                       PROBE_B=READ_EXPIRED_SNAPSHOT rows=${ROWS}"
echo "                       ExportSnapshot exit 0, CopyTable exit 0"
echo "FIXED               if  PROBE_A=REFUSED_TTL_EXPIRED"
echo "                       PROBE_B=REFUSED_TTL_EXPIRED"
echo "                       ExportSnapshot and CopyTable non-zero, with"
echo "                       SnapshotTTLExpiredException"
echo "CONTROL             PROBE_C=REFUSED_TTL_EXPIRED on BOTH sides (that is"
echo "                       HBASE-27671, the donor's own fix, not this bug)"
echo "-------------------------------------------------------------"
echo "(cluster left up; ./cleanup_HBASE-28704.sh ${side} to stop)"
