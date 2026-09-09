#!/bin/bash
# Stop the standalone HBase left running by trigger_HBASE-28704.sh.
# Usage: ./cleanup_HBASE-28704.sh [buggy|fixed|all] [hbase worktree]
side=${1:-all}
for s in $( [ "${side}" = "all" ] && echo "buggy fixed" || echo ${side} ); do
  DATA=/localtmp/julian/hbase-28704-data/${s}
  sys_dir=${2:-/localtmp/julian/hbase-28704-${s}}
  if [ -d "${DATA}/conf" ] && [ -x "${sys_dir}/bin/hbase-daemon.sh" ]; then
    HBASE_LOG_DIR=${DATA}/log HBASE_PID_DIR=${DATA}/pid HBASE_IDENT_STRING=hb28704-${s} \
      ${sys_dir}/bin/hbase-daemon.sh --config ${DATA}/conf stop master 2>/dev/null || true
  fi
  for p in $(cat ${DATA}/pid/*.pid 2>/dev/null); do kill -9 $p 2>/dev/null || true; done
  echo "stopped ${s}"
done
