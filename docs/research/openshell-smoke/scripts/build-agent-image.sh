#!/bin/bash
# Build NanoClaw's agent image in the outer sbx VM. Needs two workarounds for the sbx egress proxy:
#  1. deb.debian.org:80 is blocked, :443 is allowed (not TLS-intercepted; real Let's Encrypt chain, which node:slim has no roots for)
#     -> switch apt to https and point it at the host CA bundle for the build
#  2. build containers don't inherit proxy env -> temporary ~/.docker/config.json "proxies"
# Dockerfile is patched only in a /tmp copy (repo untouched). Tag matches ./container/build.sh.
set -euo pipefail
REPO=${REPO:-/home/arek/Projects/artebot}
CTX=/tmp/openshell-smoke/agent-build
rm -rf "$CTX"; mkdir -p "$CTX"
cp -a "$REPO/container/." "$CTX/"
cp /etc/ssl/certs/ca-certificates.crt "$CTX/proxy-ca.crt"   # host bundle: public roots + sbx proxy CA
cp /usr/local/share/ca-certificates/proxy-ca.crt "$CTX/sbx-proxy-ca.crt"
python3 -I - "$CTX/Dockerfile" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
a="ARG INSTALL_CJK_FONTS=false\n"
s=s.replace(a, a+'''COPY proxy-ca.crt /tmp/ca-bundle.crt
COPY sbx-proxy-ca.crt /usr/local/share/ca-certificates/sbx-proxy-ca.crt
RUN printf 'Acquire::https::CAInfo "/tmp/ca-bundle.crt";\\n' > /etc/apt/apt.conf.d/99ca \\
 && sed -i 's#http://deb.debian.org#https://deb.debian.org#' /etc/apt/sources.list.d/debian.sources
ARG NODE_EXTRA_CA_CERTS=/tmp/ca-bundle.crt
''',1)
b="# Chromium path for agent-browser / Playwright consumers\n"
assert b in s
s=s.replace(b,"RUN update-ca-certificates && rm /etc/apt/apt.conf.d/99ca && sed -i 's#https://deb.debian.org#http://deb.debian.org#' /etc/apt/sources.list.d/debian.sources\n"+b,1)
open(p,'w').write(s)
PY
PROJECT_ROOT="$REPO"; source "$REPO/setup/lib/install-slug.sh"
IMAGE="$(container_image_base)"
LOCK_SHA="$(sha256sum "$REPO/container/agent-runner/bun.lock" | cut -d' ' -f1)"
mkdir -p ~/.docker
[ -f ~/.docker/config.json ] || { cat > ~/.docker/config.json <<J
{"proxies":{"default":{"httpProxy":"$http_proxy","httpsProxy":"$https_proxy","noProxy":"$no_proxy"}}}
J
touch /tmp/openshell-smoke/.docker-config-created; }
cd "$CTX"
docker build --build-arg "AGENT_RUNNER_LOCK_SHA256=$LOCK_SHA" -t "$IMAGE:latest" .
echo BUILT "$IMAGE:latest"
