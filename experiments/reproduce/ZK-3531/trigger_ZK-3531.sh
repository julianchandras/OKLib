#!/bin/bash
# Pseudo-distributed reproduction of ZOOKEEPER-3531:
#   ReferenceCountedACLCache.serialize is synchronized, so a blocking write to a
#   stalled learner holds the ACL cache monitor and hangs the leader.
#
# Three ZooKeeper JVMs on one host. Fault injection is SIGSTOP on a follower
# while it is receiving a snapshot -- no root, no iptables.
#
# Usage: ./trigger_ZK-3531.sh [OathKeeper folder] [zookeeper worktree]

if [ $# -lt 2 ]; then
    echo "Usage: $0 [OathKeeper folder] [zookeeper worktree]"
    exit 1
fi
set -e
ok_dir=$1
sys_dir=$2
DATA=/localtmp/julian/zk-3531-data
HERE=${ok_dir}/experiments/reproduce/ZK-3531
export JAVA_HOME=${JAVA_HOME:-/usr/lib/jvm/java-8-openjdk-amd64}
JAVA=${JAVA_HOME}/bin/java
CP="${sys_dir}/zookeeper-server/target/classes:${sys_dir}/zookeeper-jute/target/classes:${sys_dir}/zookeeper-server/target/oklib-deps/*"
LOAD_N=${LOAD_N:-20000}

fourlw () {  # $1=port $2=cmd  -- 4lw over bash's /dev/tcp, no netcat needed
  exec 3<>/dev/tcp/127.0.0.1/$1 2>/dev/null || return 1
  printf "%s" "$2" >&3
  timeout 3 cat <&3 2>/dev/null
  exec 3<&- 3>&- 2>/dev/null || true
}

echo "=== clean state ==="
for p in $(cat ${DATA}/*/pid 2>/dev/null); do kill -CONT $p 2>/dev/null || true; kill -9 $p 2>/dev/null || true; done
rm -rf ${DATA}
mkdir -p ${DATA}

echo "=== lay out 3 servers ==="
for i in 1 2 3; do
  d=${DATA}/zk${i}
  mkdir -p ${d}/data ${d}/log
  echo ${i} > ${d}/data/myid
  sed -e "s|DATADIR|${d}/data|" -e "s|CLIENTPORT|218${i}|" ${HERE}/zoo.cfg.template > ${d}/zoo.cfg
done

# WITH_OKLIB=1 attaches OathKeeper to every server JVM: jar on the classpath,
# -Dok.* flags, MainWrapper ahead of the real main class. We launch QuorumPeerMain
# directly, so this needs no edit to conf/samples/zk-patches/install_zk-3.6.1.patch --
# and each server gets its OWN ok.ok_root_abs_path, so the three JVMs never share
# inv_prod_input, oklogs or ok.prod.log (the collision seen in the HDFS run).
OK_JAR=${ok_dir}/target/OathKeeper-1.0-SNAPSHOT-jar-with-dependencies.jar
OK_CONF=${ok_dir}/conf/samples/zk-3531-prod.properties

start_server () {  # $1 = server id
  local i=$1 d=${DATA}/zk$1
  local pre="" okflags=""
  if [ "${WITH_OKLIB:-0}" = "1" ]; then
    local okroot=${DATA}/ok-zk${i}
    mkdir -p ${okroot}/inv_prod_input/ZK-2201
    cp ${ok_dir}/inv_verify_output/ZK-2201/verified_invs ${okroot}/inv_prod_input/ZK-2201/
    pre="${OK_JAR}:"
    okflags="-Dok.invmode=prod -Dok.conf=${OK_CONF} -Dok.ok_root_abs_path=${okroot} -Dok.target_system_abs_path=${sys_dir}"
    okmain="oathkeeper.engine.MainWrapper"
  else
    okmain=""
  fi
  ${JAVA} -Xmx3g -cp "${pre}${CP}:${HERE}" -Dzookeeper.log.dir=${d}/log -Dzookeeper.4lw.commands.whitelist='*' \
    -Dlog4j.configuration=file:${HERE}/log4j.properties ${okflags} \
    ${okmain} org.apache.zookeeper.server.quorum.QuorumPeerMain ${d}/zoo.cfg > ${d}/log/server.out 2>&1 &
  echo $! > ${d}/pid
  echo "  started server ${i} pid $(cat ${d}/pid) clientPort 218${i}${WITH_OKLIB:+ [OKLib]}"
}

echo "=== start ensemble ==="
for i in 1 2 3; do start_server $i; done

echo "=== wait for quorum ==="
leader=""; 
for attempt in $(seq 1 60); do
  sleep 2
  for i in 1 2 3; do
    mode=$(fourlw 218${i} srvr 2>/dev/null | grep -i "^Mode:" | awk '{print $2}')
    [ "$mode" = "leader" ] && leader=$i
  done
  [ -n "$leader" ] && break
done
if [ -z "$leader" ]; then echo "[ERROR] no leader formed"; tail -20 ${DATA}/zk1/log/server.out; exit 1; fi
# pick a follower that is not the leader
victim=$(for i in 1 2 3; do [ "$i" != "$leader" ] && echo $i; done | tail -1)
echo "  leader = server ${leader} (port 218${leader}), victim follower = server ${victim}"

echo
echo "=== load ${LOAD_N} znodes, each with a distinct ACL ==="
# distinct ACLs => many ReferenceCountedACLCache entries => a big serializeAcls()
${JAVA} -cp "${CP}:${HERE}" -Xmx2g -Dlog4j.configuration=file:${HERE}/log4j-client.properties -DaclIdLen=${ACL_ID_LEN:-2000} ZKLoad 127.0.0.1:218${leader} ${LOAD_N} /load

echo
echo "=== kill follower ${victim}, then write past the committed-log window ==="
kill -9 $(cat ${DATA}/zk${victim}/pid); sleep 2
# zookeeper.commitLogCount is floored at 500, so >500 txns guarantees the victim
# can no longer be caught up with a DIFF and must be sent a full SNAP
${JAVA} -cp "${CP}:${HERE}" -Xmx2g -Dlog4j.configuration=file:${HERE}/log4j-client.properties -DaclIdLen=64 ZKLoad 127.0.0.1:218${leader} 1500 /gap

echo
echo "=== restart follower ${victim} and SIGSTOP it the moment the SNAP starts ==="
# A fixed delay loses the race: on loopback the whole snapshot can transfer in
# well under a second. Watch the leader log instead and stop the learner the
# instant LearnerHandler announces the snapshot, so it stops draining its socket
# mid-transfer and the leader blocks inside the synchronized aclCache.serialize.
lead_log=${DATA}/zk${leader}/log/server.out
before=$(grep -c "Sending snapshot" ${lead_log} 2>/dev/null || true); before=${before:-0}
start_server ${victim}
vpid=$(cat ${DATA}/zk${victim}/pid)
stopped=no
for t in $(seq 1 4000); do
  now=$(grep -c "Sending snapshot" ${lead_log} 2>/dev/null || true); now=${now:-0}
  if [ "${now}" -gt "${before}" ]; then
    kill -STOP ${vpid}; stopped=yes
    echo "  SIGSTOPped server ${victim} (pid ${vpid}) on 'Sending snapshot'"
    break
  fi
done
if [ "${stopped}" != "yes" ]; then
  kill -STOP ${vpid} 2>/dev/null || true
  echo "  [WARN] never saw 'Sending snapshot'; stopped server ${victim} anyway"
fi
sleep 5

echo "  leader sync decision:"
grep -ioE "Sending (SNAP|DIFF|TRUNC)" ${DATA}/zk${leader}/log/server.out | tail -3 | sed "s/^/    /"

echo
echo "=== PROBE: an ACL-touching write against the leader ==="
set +e
${JAVA} -cp "${CP}:${HERE}" -Dlog4j.configuration=file:${HERE}/log4j-client.properties ZKProbe 127.0.0.1:218${leader} ${PROBE_TIMEOUT:-25}
set -e

echo
echo "=== leader thread state ==="
lpid=$(cat ${DATA}/zk${leader}/pid)
${JAVA_HOME}/bin/jstack ${lpid} > ${DATA}/leader-jstack.txt 2>/dev/null || true
echo "  jstack -> ${DATA}/leader-jstack.txt"
echo "  threads blocked on ReferenceCountedACLCache:"
grep -c "ReferenceCountedACLCache" ${DATA}/leader-jstack.txt 2>/dev/null || echo 0
grep -B6 "ReferenceCountedACLCache" ${DATA}/leader-jstack.txt 2>/dev/null | head -30

echo
echo "-------------------------------------------------------------"
echo "REPRODUCED  if PROBE_RESULT=HUNG and the leader jstack shows"
echo "            LearnerHandler inside ReferenceCountedACLCache.serialize"
echo "            with other threads BLOCKED on the same monitor"
echo "FIXED       if PROBE_RESULT=COMPLETED (serialize clones the map"
echo "            under the lock and writes outside it)"
echo "-------------------------------------------------------------"
echo "(leave the ensemble up for inspection; ./cleanup_ZK-3531.sh to stop)"
