#!/bin/bash
# usage: mk-sandbox-nc.sh <name> <image> <policy.yaml|-> <mounts-json-file> -- <cmd...>   (guest, as smoke)
name=$1; img=$2; pol=$3; mj=$4; shift 5
args=(); [ "$pol" != "-" ] && args=(--policy "$pol")
exec openshell sandbox create --name "$name" --from "$img" "${args[@]}" \
  --driver-config-json "$(cat "$mj")" --no-keep --no-tty -- "$@"
