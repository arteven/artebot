#!/bin/bash
# Ship the NanoClaw agent image from the outer VM's Docker into the guest's Docker.
set -euo pipefail
IMG=${1:-nanoclaw-agent-v2-24afc5fb:latest}
docker save "$IMG" | /tmp/openshell-smoke/scripts/guest-ssh-smoke.sh 'docker load'
