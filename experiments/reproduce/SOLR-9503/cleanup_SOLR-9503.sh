#!/bin/bash
SOLR=${1:?usage: $0 [solr worktree]}/solr
for p in 8983 8984 8985; do ${SOLR}/bin/solr stop -p $p >/dev/null 2>&1 || true; done
sleep 2; pgrep -f "start.jar" | xargs -r kill -9 2>/dev/null || true
echo "remaining solr procs: $(pgrep -cf start.jar || echo 0)"
