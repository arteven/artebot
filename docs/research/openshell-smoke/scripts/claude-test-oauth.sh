#!/bin/sh
echo "CLAUDE_CODE_OAUTH_TOKEN shape: $(printf %s "$CLAUDE_CODE_OAUTH_TOKEN" | cut -c1-24)... len ${#CLAUDE_CODE_OAUTH_TOKEN}"
env | grep -i '^\(https\?_proxy\|no_proxy\|SSL_CERT\|NODE_EXTRA\|REQUESTS_CA\)' | sed 's/=.*/=<set>/'
cd /home/node
timeout 120 claude -p 'reply with OK' --output-format json --max-turns 1 2>&1 | head -c 1500
echo "rc=$?"
