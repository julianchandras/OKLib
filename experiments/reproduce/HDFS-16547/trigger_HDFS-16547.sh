#!/bin/bash
# Pseudo-distributed reproduction of HDFS-16547:
#   a NameNode in safe mode can still be transitioned to observer.
# Two NameNode JVMs on one host, no datanodes, no ZKFC, no journalnodes.
#
# Usage: ./trigger_HDFS-16547.sh [OathKeeper folder] [hadoop worktree]

if [ $# -lt 2 ]; then
    echo "Usage: $0 [OathKeeper folder] [hadoop worktree]"
    exit 1
fi

set -e
ok_dir=$1
sys_dir=$2
DATA=/localtmp/julian/hdfs-16547-data
export JAVA_HOME=${JAVA_HOME:-/usr/lib/jvm/java-8-openjdk-amd64}

version=$(perl -ne 'print and last if s/.*<version>(.*)<\/version>.*/\1/;' < ${sys_dir}/pom.xml)
dist=${sys_dir}/hadoop-dist/target/hadoop-${version}
if [ ! -d "$dist" ]; then echo "[ERROR] no dist at $dist -- build first"; exit 1; fi

# Both NameNodes bind localhost, so DFSUtil.getSuffixIDs cannot tell them apart
# and aborts with "Configuration has multiple addresses that match local node's
# address". HAUtil.getNameNodeId honours dfs.ha.namenode.id ahead of matching --
# but that is read from Configuration, NOT from a -D JVM flag, so each NameNode
# needs its own HADOOP_CONF_DIR carrying its own id.
make_conf () {   # $1 = nn1|nn2
  local cdir=${DATA}/conf-$1
  rm -rf ${cdir}; mkdir -p ${cdir}
  cp -a ${dist}/etc/hadoop/. ${cdir}/
  cp ${ok_dir}/experiments/reproduce/HDFS-16547/core-site.xml ${cdir}/
  cp ${ok_dir}/experiments/reproduce/HDFS-16547/hdfs-site.xml ${cdir}/
  python3 - "$cdir/hdfs-site.xml" "$1" <<'PY'
import sys
path, nnid = sys.argv[1], sys.argv[2]
s = open(path).read()
add = """  <property>
    <name>dfs.nameservice.id</name>
    <value>okcluster</value>
  </property>
  <property>
    <name>dfs.ha.namenode.id</name>
    <value>%s</value>
  </property>
</configuration>""" % nnid
open(path, "w").write(s.replace("</configuration>", add))
PY
  sed -i "s|^export JAVA_HOME=.*$|export JAVA_HOME=${JAVA_HOME}|g" ${cdir}/hadoop-env.sh
  grep -q "^export JAVA_HOME=" ${cdir}/hadoop-env.sh || echo "export JAVA_HOME=${JAVA_HOME}" >> ${cdir}/hadoop-env.sh
}

# HADOOP_PID_DIR / HADOOP_LOG_DIR are per-host, not per-namenode: two NNs on one
# box would otherwise share hadoop-$USER-namenode.pid and clobber each other.
nn_env () {   # $1 = nn1|nn2
  export HADOOP_CONF_DIR=${DATA}/conf-$1
  export HADOOP_PID_DIR=${DATA}/pid-$1
  export HADOOP_LOG_DIR=${DATA}/log-$1
  mkdir -p ${HADOOP_PID_DIR} ${HADOOP_LOG_DIR}
}

wait_rpc () {  # $1 = port
  for i in $(seq 1 60); do
    (ss -lnt 2>/dev/null || netstat -lnt) | grep -q ":$1 " && return 0
    sleep 2
  done
  echo "[ERROR] nothing listening on $1"; return 1
}

echo "=== clean state ==="
cd ${dist}
for nn in nn1 nn2; do
  if [ -d ${DATA}/conf-${nn} ]; then nn_env ${nn}; bin/hdfs --daemon stop namenode 2>/dev/null || true; fi
done
rm -rf ${DATA}
mkdir -p ${DATA}/nn1 ${DATA}/nn2 ${DATA}/shared-edits ${DATA}/tmp

echo "=== build per-namenode config dirs ==="
# The build excludes the yarn reactor (catalog-webapp needs the npm registry),
# so share/hadoop/yarn is absent and hadoop_bootstrap aborts with
# "Invalid HADOOP_YARN_HOME". It is only a `-d` test; HDFS needs no yarn jars.
mkdir -p ${dist}/share/hadoop/yarn/lib
make_conf nn1
make_conf nn2

echo "=== format nn1 + shared edits ==="
nn_env nn1
bin/hdfs namenode -format -force -nonInteractive -clusterId okcluster-16547
bin/hdfs namenode -initializeSharedEdits -force

echo "=== start nn1 ==="
bin/hdfs --daemon start namenode
wait_rpc 8020

echo "=== bootstrap + start nn2 ==="
nn_env nn2
bin/hdfs namenode -bootstrapStandby -force
bin/hdfs --daemon start namenode
wait_rpc 8022

echo
echo "=== initial state (expect both standby) ==="
bin/hdfs haadmin -getAllServiceState

echo
echo "=== put BOTH namenodes into safe mode ==="
# fs.defaultFS is the logical URI okcluster, so DFSAdmin.setSafeMode fans out to
# every NN in the nameservice with isChecked=false -> OperationCategory.UNCHECKED,
# which a standby accepts. Same effect as the unit test's
# NameNodeAdapter.enterSafeMode(nn, false).
bin/hdfs dfsadmin -safemode enter

echo
echo "=== THE BUG: transition a safe-mode namenode to observer ==="
set +e
echo yes | bin/hdfs haadmin -transitionToObserver -forcemanual nn1
rc=$?
set -e
echo "transitionToObserver exit code: ${rc}"

echo
echo "=== final state ==="
bin/hdfs haadmin -getAllServiceState
echo
echo "-------------------------------------------------------------"
echo "REPRODUCED  if exit code is 0 and nn1 now reads 'observer'"
echo "            (a namenode serving reads while still in safe mode)"
echo "FIXED       if exit code is non-zero and nn1 stays 'standby',"
echo "            with 'still not leave safemode' on stderr"
echo "-------------------------------------------------------------"
