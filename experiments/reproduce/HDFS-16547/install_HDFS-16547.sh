#!/bin/bash
# Build the buggy (pre-fix) hadoop for HDFS-16547 in an isolated worktree.
#
# Usage: ./install_HDFS-16547.sh [OathKeeper folder] [main hadoop repo] [worktree path]
#
# Unlike the older reproduce cases this does NOT check out inside the main hadoop
# repo. HDFS-16547 sits on 3.4.0-SNAPSHOT while the OKLib HDFS tickets pin much
# older commits, and a checkout would wipe the target/ trees that every
# conf/samples/hdfs-collections/*.properties java_class_path points at.
# A worktree shares .git and leaves the main checkout alone.

if [ $# -lt 2 ]; then
    echo "Usage: $0 [OathKeeper folder] [main hadoop repo] [worktree path]"
    exit 1
fi
set -ex
ok_dir=$1
main_repo=$2
worktree=${3:-/localtmp/julian/hadoop-16547}
export JAVA_HOME=${JAVA_HOME:-/usr/lib/jvm/java-8-openjdk-amd64}

# dc2fba45fef is the parent of 8f971b0e541 ("HDFS-16547. [SBN read] Namenode in
# safe mode should not be transfer to observer state"), i.e. the last commit
# that still has the bug.
buggy=dc2fba45fef68ff65488a1e587e6211cc3386188

if [ ! -d "${worktree}" ]; then
  git -C ${main_repo} worktree add --detach ${worktree} ${buggy}
fi

cd ${worktree}
# Same goals as the older reproduce cases, plus two adjustments forced by the
# 3.4.0-SNAPSHOT reactor:
#
# 1. Exclude the three hadoop-yarn-applications-catalog modules. The webapp runs
#    `yarn install` against the npm registry and dies offline; catalog-docker
#    depends on its war, so excluding only the webapp just moves the failure.
#    Nothing under hadoop-dist depends on any of them.
# 2. -fae (--fail-at-end). The hadoop-yarn-project aggregator still wants the
#    excluded war and fails at module 67, but Apache Hadoop Distribution is
#    module 105. Without -fae the reactor stops and the dist is never built.
CATALOG=hadoop-yarn-project/hadoop-yarn/hadoop-yarn-applications/hadoop-yarn-applications-catalog
mvn clean package -Pdist -DskipTests -Dmaven.javadoc.skip=true -Dtar -Drat.skip=true -fae \
  -pl "!${CATALOG},!${CATALOG}/hadoop-yarn-applications-catalog-webapp,!${CATALOG}/hadoop-yarn-applications-catalog-docker"

# Expect a 110-module reactor: 109 SUCCESS including "Apache Hadoop Distribution",
# and one FAILURE on hadoop-yarn-project. That failure is expected and harmless.

# To build the FIXED side for comparison, from the same worktree:
#   git -C ${worktree} checkout -f 8f971b0e5413b491a2c7043bd25b046777e07395
#   mvn clean package -Pdist -DskipTests -Dmaven.javadoc.skip=true -Dtar -Drat.skip=true
