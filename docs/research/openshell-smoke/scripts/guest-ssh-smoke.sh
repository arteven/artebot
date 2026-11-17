#!/bin/bash
# like guest-ssh.sh but as user "smoke" (docker group, systemd --user session for the gateway)
exec ssh -i /tmp/openshell-smoke/guest/id_ed25519 -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=20 -o ServerAliveInterval=30 smoke@127.0.0.1 "$@"
