#!/bin/bash
# usage: guest-ssh.sh [user@]  <command...>   (default user root)
exec ssh -i /tmp/openshell-smoke/guest/id_ed25519 -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=20 -o ServerAliveInterval=30 root@127.0.0.1 "$@"
