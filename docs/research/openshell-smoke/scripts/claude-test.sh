#!/bin/sh
echo "ANTHROPIC_API_KEY shape: $(printf %s "$ANTHROPIC_API_KEY" | cut -c1-24)... len ${#ANTHROPIC_API_KEY}"
env | grep -i '^\(https\?_proxy\|no_proxy\|SSL_CERT\|NODE_EXTRA\|REQUESTS_CA\)' | sed 's/=.*/=<set>/'
cd /home/node
timeout 120 claude -p 'reply with OK' --output-format json --max-turns 1 2>&1 | head -c 1500
echo "rc=$?"
