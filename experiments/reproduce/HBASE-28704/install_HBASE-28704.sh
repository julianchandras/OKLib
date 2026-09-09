#!/bin/bash
# Build the buggy (pre-fix) and fixed HBase for HBASE-28704 in isolated worktrees.
#
# Usage: ./install_HBASE-28704.sh [OathKeeper folder] [main hbase repo] [side]
#          side = buggy | fixed | both   (default: both)
#
# Worktrees, not a checkout in the main repo: /localtmp/julian/hbase is pinned at
# 620ab79b (HBASE-27671, 2.5.4-era) and is the *donor* for this pair, and
# run_engine.sh verify does `git reset --hard` on it.

if [ $# -lt 2 ]; then
    echo "Usage: $0 [OathKeeper folder] [main hbase repo] [buggy|fixed|both]"
    exit 1
fi
set -e
ok_dir=$1
main_repo=$2
side=${3:-both}
export JAVA_HOME=${JAVA_HOME:-/usr/lib/jvm/java-8-openjdk-amd64}
export PATH=${JAVA_HOME}/bin:${PATH}

# 60d6ebdc is "HBASE-28704 The expired snapshot can be read by CopyTable or
# ExportSnapshot (branch-2)"; its parent 0e65ff6a is the last commit with the bug.
fixed_sha=60d6ebdcf34735e95d954dd0798e51584eb1dc7e
buggy_sha=0e65ff6aab0fac10c8e86755de1ec8c21f669fbd

# hbase-assembly is required even though we never unpack a tarball: it is the module
# that writes hbase-build-configuration/target/cached_classpath.txt, which bin/hbase
# needs to run out of a source tree (its `in_dev_env` path).
build_flags="-DskipTests -Dmaven.javadoc.skip=true -Dcyclonedx.skip=true \
  -Dcheckstyle.skip=true -Dfindbugs.skip=true -Dspotbugs.skip=true -Dwarbucks.skip=true \
  -Drat.skip=true -Dmaven.gitcommitid.skip=true \
  -pl hbase-server,hbase-mapreduce,hbase-testing-util,hbase-assembly -am"

build_one () {   # $1 = buggy|fixed  $2 = sha
  local name=$1 sha=$2
  local wt=/localtmp/julian/hbase-28704-${name}
  echo "=== ${name} (${sha:0:10}) -> ${wt} ==="
  if [ ! -d "${wt}" ]; then
    git -C ${main_repo} worktree add --detach ${wt} ${sha}
  fi
  cd ${wt}
  mvn clean package ${build_flags} 2>&1 | tee ${wt}/build.log | tail -40
  # bin/hbase runs from a source tree only if this exists
  test -f ${wt}/hbase-build-configuration/target/cached_classpath.txt \
    || { echo "[ERROR] ${name}: cached_classpath.txt missing -- hbase-assembly did not run"; exit 1; }
  echo "=== ${name} BUILD OK ==="
}

case ${side} in
  buggy) build_one buggy ${buggy_sha} ;;
  fixed) build_one fixed ${fixed_sha} ;;
  both)  build_one buggy ${buggy_sha}; build_one fixed ${fixed_sha} ;;
  *) echo "unknown side: ${side}"; exit 1 ;;
esac
