#!/bin/bash
# Build the buggy (pre-fix) ZooKeeper for ZOOKEEPER-3531 in an isolated worktree.
#
# Usage: ./install_ZK-3531.sh [OathKeeper folder] [main zookeeper repo] [worktree path]
#
# A worktree, not a checkout in the main repo: /localtmp/julian/zookeeper is
# pinned at 71dd96a23 (ZOOKEEPER-2201, 2015, ant-era) and is the *donor* for this
# pair. ZK-3531 is 3.6.0-SNAPSHOT and builds with maven.

if [ $# -lt 2 ]; then
    echo "Usage: $0 [OathKeeper folder] [main zookeeper repo] [worktree path]"
    exit 1
fi
set -ex
ok_dir=$1
main_repo=$2
worktree=${3:-/localtmp/julian/zookeeper-3531}
export JAVA_HOME=${JAVA_HOME:-/usr/lib/jvm/java-8-openjdk-amd64}

# 2dcb5e799 is the parent of f4c7b698b ("ZOOKEEPER-3531: Synchronization on
# ACLCache cause cluster to hang..."), i.e. the last commit with the bug.
buggy=2dcb5e799ec02a2c6a6c7bad80c47169dc095271

if [ ! -d "${worktree}" ]; then
  git -C ${main_repo} worktree add --detach ${worktree} ${buggy}
fi

cd ${worktree}
# -Dmaven.gitcommitid.skip: git-commit-id-plugin 2.2.5 cannot resolve HEAD in a
# worktree (.git is a file, not a directory) and fails with "Missing unknown <sha>".
mvn clean package -DskipTests -Dmaven.javadoc.skip=true -Drat.skip=true \
    -Dcheckstyle.skip=true -Dspotbugs.skip=true -Dmaven.gitcommitid.skip=true \
    -pl zookeeper-jute,zookeeper-server -am

# runtime classpath for the ensemble and the client helpers
# NOTE: includeScope=test, not runtime -- metrics-core and other ZK runtime deps
# are declared <scope>provided</scope> (zookeeper-server/pom.xml:125), so a
# runtime-scoped copy omits them and QuorumPeerMain dies with
# NoClassDefFoundError: com/codahale/metrics/Reservoir.
mvn dependency:copy-dependencies -DincludeScope=test \
    -DoutputDirectory=${worktree}/zookeeper-server/target/oklib-deps \
    -Dmaven.gitcommitid.skip=true -pl zookeeper-server

# To build the FIXED side for comparison, use a second worktree:
#   git -C ${main_repo} worktree add --detach ${worktree}-fixed f4c7b698bd239bcd15ee380d2ee38814dba432cd
