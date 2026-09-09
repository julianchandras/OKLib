#!/bin/bash
# Pseudo-distributed reproduction of SOLR-9503:
#   NPE in replica placement when the overseer-role rule is combined with another rule.
#
# Root cause (ReplicaAssigner.java:425 on the buggy parent):
#   if (context.getTags().keySet().containsAll(context.snitchInfo.getTagNames())) { ...record... }
# A node whose snitch returns only SOME of the requested tags is recorded nowhere, so it is
# absent from nodeVsTags. With rule=role:!overseer the nodes WITHOUT the overseer role have no
# `role` tag, drop out of the map, and the second rule then dereferences nothing.
#
# 3 SolrCloud JVMs on one host; node 1 also runs the embedded ZooKeeper.
# Usage: ./trigger_SOLR-9503.sh [OathKeeper folder] [solr worktree]

if [ $# -lt 2 ]; then echo "Usage: $0 [OathKeeper folder] [solr worktree]"; exit 1; fi
set -e
ok_dir=$1
sys_dir=$2
DATA=/localtmp/julian/solr-9503-data
SOLR=${sys_dir}/solr
export JAVA_HOME=${JAVA_HOME:-/usr/lib/jvm/java-8-openjdk-amd64}
export PATH=${JAVA_HOME}/bin:${PATH}
ZKPORT=9983

api () { curl -sS "http://localhost:8983/solr/admin/collections?$1&wt=json"; }

echo "=== clean state ==="
for p in 8983 8984 8985; do ${SOLR}/bin/solr stop -p $p >/dev/null 2>&1 || true; done
pgrep -f "start.jar" | xargs -r kill -9 2>/dev/null || true
rm -rf ${DATA}; mkdir -p ${DATA}

# SOLR_LOGS_DIR must be per node. bin/solr passes it as -Dsolr.log.dir and also
# rotates the directory on every start, so three nodes sharing server/logs means
# node 1's startup log (including any embedded-ZK failure) is destroyed by node 3.
start_node () {  # $1 = node index, $2... = extra bin/solr args
  local i=$1; shift
  local port=$((8982+i)) home=${DATA}/node${i}
  mkdir -p ${home} ${DATA}/logs${i}
  # zoo.cfg as well as solr.xml: with -DzkRun, SolrZkServer reads zoo.cfg from the
  # solr home and dies with "zoo.cfg file is missing" if it is absent, which shows
  # up only as a 404 on every /solr/admin endpoint.
  cp ${SOLR}/server/solr/solr.xml ${SOLR}/server/solr/zoo.cfg ${home}/ 2>/dev/null || true
  SOLR_LOGS_DIR=${DATA}/logs${i} \
    ${SOLR}/bin/solr start -c -p ${port} -s ${home} "$@" ${SOLR_EXTRA_OPTS:+-a "${SOLR_EXTRA_OPTS}"}
}

echo "=== start node 1 (hosts the embedded ZK on ${ZKPORT}) ==="
start_node 1
# Embedded ZK is started inside node 1's JVM by SolrDispatchFilter. Nodes 2 and 3
# must not be launched until it is actually bound, or they die with
# "Could not connect to ZooKeeper localhost:9983 within 30000 ms".
echo "=== wait for embedded ZK on ${ZKPORT} ==="
zkup=no
for t in $(seq 1 60); do
  if (ss -lnt 2>/dev/null || netstat -lnt) | grep -q ":${ZKPORT} "; then zkup=yes; break; fi
  sleep 2
done
echo "  embedded ZK listening: ${zkup}"
if [ "$zkup" != "yes" ]; then
  echo "[ERROR] embedded ZK never bound; node 1 log:"; tail -30 ${DATA}/logs1/solr.log 2>/dev/null; exit 1
fi

echo "=== start nodes 2 and 3 ==="
start_node 2 -z localhost:${ZKPORT}
start_node 3 -z localhost:${ZKPORT}

echo "=== wait for 3 live nodes ==="
for t in $(seq 1 60); do
  n=$(api "action=CLUSTERSTATUS" | grep -o '_solr' | wc -l)
  live=$(api "action=CLUSTERSTATUS" | python3 -c "import sys,json;d=json.load(sys.stdin);print(len(d['cluster']['live_nodes']))" 2>/dev/null || echo 0)
  [ "${live:-0}" -ge 3 ] && break
  sleep 2
done
echo "  live nodes: ${live}"
api "action=CLUSTERSTATUS" | python3 -c "import sys,json;d=json.load(sys.stdin);print('  ',d['cluster']['live_nodes'])" 2>/dev/null || true

echo
echo "=== upload a configset (CREATE needs one, else 400 'No config set found') ==="
${SOLR}/server/scripts/cloud-scripts/zkcli.sh -zkhost localhost:${ZKPORT} \
  -cmd upconfig -confname repro9503conf \
  -confdir ${SOLR}/server/solr/configsets/basic_configs/conf 2>&1 | tail -2

echo
echo "=== give node 1 the overseer role (nodes 2 and 3 get NO role tag) ==="
# The node name must be the one ZooKeeper actually registered -- Solr registers by
# resolved host address, not 127.0.0.1, and ADDROLE returns status 0 for a node
# name that does not exist, silently giving nobody the role.
NODE1=$(api "action=CLUSTERSTATUS" | python3 -c "
import sys,json
ns=json.load(sys.stdin)['cluster']['live_nodes']
print(next(n for n in ns if n.split(':')[1].startswith('8983')))")
echo "  overseer node = ${NODE1}"
api "action=ADDROLE&role=overseer&node=${NODE1}"; echo
sleep 3
echo "  roles now: $(api 'action=CLUSTERSTATUS' | python3 -c "import sys,json;print(json.load(sys.stdin)['cluster'].get('roles'))" 2>/dev/null)"

echo
echo "=== THE BUG: create a collection combining the role rule with a second rule ==="
set +e
out=$(api "action=CREATE&name=repro9503&numShards=1&replicationFactor=2&maxShardsPerNode=2&collection.configName=repro9503conf&rule=role:!overseer&rule=freedisk:%3E1")
rc=$?
set -e
echo "$out" | head -40
echo
echo "=== did it NPE? ==="
# The HTTP response only carries a bare SolrException with msg:null -- the actual
# NullPointerException is logged server-side, so the verdict has to read the logs.
# `|| true` on both: grep exits 1 when it finds nothing, which under `set -e` aborts
# the script on the FIXED side -- exactly the run where we most need the verdict.
npe=$(grep -l "NullPointerException" ${DATA}/logs*/solr.log 2>/dev/null | wc -l || true)
in_rule=$(grep -h -A6 "NullPointerException" ${DATA}/logs*/solr.log 2>/dev/null \
          | grep -c "org.apache.solr.cloud.rule.Rule" || true)
npe=${npe:-0}; in_rule=${in_rule:-0}
if [ "${npe}" -gt 0 ] && [ "${in_rule}" -gt 0 ]; then
  echo "  REPRODUCED - NullPointerException inside org.apache.solr.cloud.rule.Rule"
elif echo "$out" | grep -q '"status":0'; then
  echo "  FIXED - collection created, no NPE"
else
  echo "  INCONCLUSIVE - see response above"
fi
echo
echo "=== NPE stack from the node logs ==="
grep -h -A14 "NullPointerException" ${DATA}/logs*/solr.log 2>/dev/null | head -22 || true
echo
echo "-------------------------------------------------------------"
echo "REPRODUCED  if the CREATE response carries a NullPointerException"
echo "            from Rule.tryAssignNodeToShard / ReplicaAssigner"
echo "FIXED       if the collection is created (status 0)"
echo "-------------------------------------------------------------"
