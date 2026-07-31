#!/bin/bash
# Build step for the 2016-era OathKeeper Solr tickets (SOLR-8728 / 9251 / 9503), Ivy 2.3.0.
# Invoked from each collection's compile_test_cmd; runs with cwd = the lucene-solr monorepo root.
# 2017+ tickets use build_solr_ivy24.sh instead.
set -e
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ivy_version=2.3.0
ivy_lib="${here}/antlib/ivy-${ivy_version}"
# Point Ant at our own Ivy under antlib/ instead of the global ~/.ant/lib
ant_ivy_args=(-nouserlib -lib "${ivy_lib}" -Divy_install_path="${ivy_lib}")

# 0a. Wipe stale cross-era build output
rm -rf solr/build lucene/build

# 0b. Clear stale Ivy cache locks that hang the next resolve
find "${HOME}/.ivy2" -name '*.lck' -delete 2>/dev/null || true

# 1. Repoint dead/HTTP-only Ivy repositories to live HTTPS mirrors.
bash "${here}/fix_ivy_urls.sh"

# 2. Fetch the Ivy jar over HTTPS (since the build's own ivy-bootstrap can't).
if [ ! -f "${ivy_lib}/ivy-${ivy_version}.jar" ]; then
  echo "[build_solr] fetching Ivy ${ivy_version}"
  mkdir -p "${ivy_lib}"
  curl -fsSL -o "${ivy_lib}/ivy-${ivy_version}.jar" \
    "https://repo1.maven.org/maven2/org/apache/ivy/ivy/${ivy_version}/ivy-${ivy_version}.jar"
fi

# 3. Build (Ant build lives in solr/)
( cd solr && ant "${ant_ivy_args[@]}" compile-test )

# 4. Assemble solr/build/lucene-libs -- compile-test builds the lucene module jars but doesn't
#    copy them where java_class_path expects. Idempotent; re-runs each checkout.
if ! ( cd solr/core && ant "${ant_ivy_args[@]}" lucene-jars-to-solr ); then
  echo "[build_solr] 'lucene-jars-to-solr' target unavailable; falling back to manual flatten-copy"
  mkdir -p solr/build/lucene-libs
  find lucene/build -name 'lucene-*.jar' -exec cp -f {} solr/build/lucene-libs/ \;
fi
echo "[build_solr] solr/build/lucene-libs now has $(ls solr/build/lucene-libs 2>/dev/null | wc -l) lucene jars"
