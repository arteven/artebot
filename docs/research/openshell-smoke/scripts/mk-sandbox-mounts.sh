#!/bin/bash
# usage: mk-sandbox-mounts.sh <name> <image> <policy.yaml|-> -- <cmd...>   (run in the guest as smoke)
# rw bind: /home/smoke/nc/rw -> /mnt/rw ; ro bind: /home/smoke/nc/ro -> /mnt/ro
name=$1; img=$2; pol=$3; shift 4
args=(); [ "$pol" != "-" ] && args=(--policy "$pol")
exec openshell sandbox create --name "$name" --from "$img" "${args[@]}" \
  --driver-config-json '{"docker":{"mounts":[{"type":"bind","source":"/home/smoke/nc/rw","target":"/mnt/rw","read_only":false},{"type":"bind","source":"/home/smoke/nc/ro","target":"/mnt/ro","read_only":true}]}}' \
  --no-keep --no-tty -- "$@"
