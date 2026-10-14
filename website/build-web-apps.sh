#!/bin/sh
# Builds the browser apps into the site, so nostrvault.app serves them:
#   web-relay/ -> website/relay/   (vite writes there itself)
#   web-vault/ -> website/vault/   (vite writes web-vault/dist/, copied here)
# Runs inside website/Dockerfile at deploy time; also works on a host with Go and Node.
# An app missing from this checkout is skipped. web-vault imports web-relay's code and haven.wasm, so it needs both.
set -eu
cd "$(dirname "$0")/.."

if [ -d web-relay ]; then
  web-relay/tools/build-haven-wasm.sh
  (cd web-relay && npm ci --no-audit --no-fund && npm run build)
  [ -f website/relay/index.html ] || { echo "web-relay build wrote no website/relay/index.html" >&2; exit 1; }
else
  echo "build-web-apps: no web-relay/ in this checkout, /relay/ is not built"
fi

if [ -d web-vault ]; then
  [ -d web-relay ] || { echo "web-vault needs web-relay/ (its relay code and haven.wasm)" >&2; exit 1; }
  (cd web-vault && npm ci --no-audit --no-fund && npm run build)
  rm -rf website/vault
  cp -R web-vault/dist website/vault
  [ -f website/vault/index.html ] || { echo "web-vault build wrote no index.html" >&2; exit 1; }
else
  echo "build-web-apps: no web-vault/ in this checkout, /vault/ is not built"
fi
