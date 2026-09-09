#!/bin/bash
# Attach OKLib to the built dist -- the equivalent of
#   ./run_engine.sh install conf/samples/hdfs-16547.properties hdfs
# but targeted at a worktree instead of ${system_dir_path} from the conf file.
#
# Usage: ./install_oklib_HDFS-16547.sh [OathKeeper folder] [hadoop worktree]

if [ $# -lt 2 ]; then
    echo "Usage: $0 [OathKeeper folder] [hadoop worktree]"
    exit 1
fi
set -e
ok_dir=$1
sys_dir=$2
conf_file=${ok_dir}/conf/samples/hdfs-16547.properties
version=$(perl -ne 'print and last if s/.*<version>(.*)<\/version>.*/\1/;' < ${sys_dir}/pom.xml)
dist=${sys_dir}/hadoop-dist/target/hadoop-${version}

if [ ! -f "${ok_dir}/target/OathKeeper-1.0-SNAPSHOT-jar-with-dependencies.jar" ]; then
  echo "[ERROR] ok_lib jar missing. Run: mvn clean package -DskipTests"
  exit 1
fi

# The patch rewrites hadoop_start_daemon so every daemon JVM gets
#   1) OKLib on the CLASSPATH  2) the -Dok.* flags  3) MainWrapper as main class
cd ${sys_dir}
git checkout -f -- hadoop-common-project/hadoop-common/src/main/bin/hadoop-functions.sh
perl -p -e "s|OK_DIR_MACRO|${ok_dir}|g and s|SYS_DIR_MACRO|${sys_dir}|g and s|CONF_PATH_MACRO|${conf_file}|g" \
  ${ok_dir}/conf/samples/hdfs-patches/install_hdfs.patch > /tmp/ok_install_16547.patch
git apply /tmp/ok_install_16547.patch
rm -f /tmp/ok_install_16547.patch

# run_engine.sh install ships the patched script into the dist rather than rebuilding
cp hadoop-common-project/hadoop-common/src/main/bin/hadoop-functions.sh ${dist}/libexec/

echo "=== attached; the daemon launch line is now ==="
grep -n "MainWrapper\|OKFLAGS=\|CLASSPATH=\"" ${dist}/libexec/hadoop-functions.sh | head

echo
echo "=== invariants that will be loaded from ${ok_dir}/inv_prod_input ==="
for d in ${ok_dir}/inv_prod_input/*/; do
  echo "  $(basename $d): $(grep -c '"template"' ${d}/verified_invs 2>/dev/null || echo 0) invariants"
done
