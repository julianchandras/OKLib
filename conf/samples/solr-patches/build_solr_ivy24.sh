#!/bin/bash
# Build step for the 2017+ OathKeeper Solr tickets (SOLR-11616, SOLR-13872), Ivy 2.4.0.
# Invoked from each collection's compile_test_cmd; runs with cwd = the lucene-solr monorepo root.
#
# Same as build_solr.sh except for the Ivy version: these trees bootstrap 2.4.0 and hard-fail if the
# 2016-era 2.3.0 jar is on the Ant path, so we can't share ~/.ant/lib across eras -- keep our own
# 2.4.0 jar under antlib/ and point Ant only at it.
set -e
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ivy_version=2.4.0
ivy_lib="${here}/antlib/ivy-${ivy_version}"
ant_ivy_args=(-nouserlib -lib "${ivy_lib}" -Divy_install_path="${ivy_lib}")

# 0a. Wipe stale cross-era build output.
rm -rf solr/build lucene/build

# 0b. Clear stale Ivy cache locks that hang the next resolve.
find "${HOME}/.ivy2" -name '*.lck' -delete 2>/dev/null || true

# 1. Repoint dead/HTTP-only Ivy repositories to live HTTPS mirrors.
bash "${here}/fix_ivy_urls.sh"

# 2. Fetch the Ivy jar over HTTPS (idempotent; re-runs after every checkout).
if [ ! -f "${ivy_lib}/ivy-${ivy_version}.jar" ]; then
  echo "[build_solr_ivy24] fetching Ivy ${ivy_version}"
  mkdir -p "${ivy_lib}"
  curl -fsSL -o "${ivy_lib}/ivy-${ivy_version}.jar" \
    "https://repo1.maven.org/maven2/org/apache/ivy/ivy/${ivy_version}/ivy-${ivy_version}.jar"
fi

# 3. Build (Ant build lives in solr/)
( cd solr && ant "${ant_ivy_args[@]}" compile-test )

# 4. Assemble solr/build/lucene-libs
if ! ( cd solr/core && ant "${ant_ivy_args[@]}" lucene-jars-to-solr ); then
  echo "[build_solr_ivy24] 'lucene-jars-to-solr' target unavailable; falling back to manual flatten-copy"
  mkdir -p solr/build/lucene-libs
  find lucene/build -name 'lucene-*.jar' -exec cp -f {} solr/build/lucene-libs/ \;
fi
echo "[build_solr_ivy24] solr/build/lucene-libs now has $(ls solr/build/lucene-libs 2>/dev/null | wc -l) lucene jars"
