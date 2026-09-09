#!/bin/bash
# Usage: ./cleanup_HDFS-16547.sh [hadoop worktree]
sys_dir=${1:?usage: $0 [hadoop worktree]}
DATA=/localtmp/julian/hdfs-16547-data
export JAVA_HOME=${JAVA_HOME:-/usr/lib/jvm/java-8-openjdk-amd64}
version=$(perl -ne 'print and last if s/.*<version>(.*)<\/version>.*/\1/;' < ${sys_dir}/pom.xml)
cd ${sys_dir}/hadoop-dist/target/hadoop-${version}
for nn in nn1 nn2; do
  HADOOP_PID_DIR=${DATA}/pid-${nn} HADOOP_LOG_DIR=${DATA}/log-${nn} \
    HDFS_NAMENODE_OPTS="-Ddfs.ha.namenode.id=${nn}" \
    bin/hdfs --daemon stop namenode 2>/dev/null || true
done
sleep 2
jps | grep -E "NameNode|MainWrapper" | cut -d' ' -f1 | xargs -r kill -9
jps
