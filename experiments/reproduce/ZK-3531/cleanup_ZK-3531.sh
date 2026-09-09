#!/bin/bash
DATA=/localtmp/julian/zk-3531-data
for f in ${DATA}/*/pid; do p=$(cat $f 2>/dev/null); [ -n "$p" ] && { kill -CONT $p 2>/dev/null; kill -9 $p 2>/dev/null; }; done
sleep 1
pgrep -f QuorumPeerMain | xargs -r kill -9
echo "stopped; remaining QuorumPeerMain: $(pgrep -cf QuorumPeerMain)"
